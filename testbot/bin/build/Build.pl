#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs the 'build' task in the build machine. Specifically this applies a
# conformance test patch, rebuilds the impacted test and retrieves the
# resulting 32 and 64 bit binaries.
#
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014, 2017-2018 Francois Gouget
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA

use strict;

sub BEGIN
{
  if ($0 !~ m=^/=)
  {
    # Turn $0 into an absolute path so it can safely be used in @INC
    require Cwd;
    $0 = Cwd::cwd() . "/$0";
  }
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
  $::BuildEnv = 1;
}

use WineTestBot::Config;
use WineTestBot::PatchUtils;

sub InfoMsg(@)
{
  my $OldUMask = umask(002);
  if (open LOGFILE, ">>$LogDir/Build.log")
  {
    print LOGFILE @_;
    close LOGFILE;
  }
  umask($OldUMask);
}

sub LogMsg(@)
{
  my $OldUMask = umask(002);
  if (open LOGFILE, ">>$LogDir/Build.log")
  {
    print LOGFILE "Build: ", @_;
    close LOGFILE;
  }
  umask($OldUMask);
}

sub FatalError(@)
{
  LogMsg @_;

  exit 1;
}

my $ncpus;
sub CountCPUs()
{
  if (open(my $fh, "<", "/proc/cpuinfo"))
  {
    # Linux
    map { $ncpus++ if (/^processor/); } <$fh>;
    close($fh);
  }
  $ncpus ||= 1;
}

sub ApplyPatch($)
{
  my ($PatchFile) = @_;

  InfoMsg "Applying patch\n";
  system("( cd $DataDir/wine && set -x && " .
         "  git apply --verbose $PatchFile && " .
         "  git add -A " .
         ") >> $LogDir/Build.log 2>&1");
  if ($? != 0)
  {
    LogMsg "Patch failed to apply\n";
    return undef;
  }

  my $Impacts = GetPatchImpact($PatchFile, "nounits");
  if ($Impacts->{Makefiles})
  {
    InfoMsg "\nRunning make_makefiles\n";
    system("( cd $DataDir/wine && set -x && " .
           " ./tools/make_makefiles " .
           ") >> $LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "make_makefiles failed\n";
      return undef;
    }
  }

  if ($Impacts->{Autoconf} && !$Impacts->{HasConfigure})
  {
    InfoMsg "\nRunning autoconf\n";
    system("( cd $DataDir/wine && set -x && " .
           "  autoconf " .
           ") >>$LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "Autoconf failed\n";
      return undef;
    }
  }

  return $Impacts;
}

sub BuildNative()
{
  mkdir "$DataDir/build-native" if (! -d "$DataDir/build-native");

  InfoMsg "\nRebuilding native tools\n";
  system("( cd $DataDir/build-native && set -x && " .
         "  time make -j$ncpus __tooldeps__ " .
         ") >>$LogDir/Build.log 2>&1");
  if ($? != 0)
  {
    LogMsg "Rebuild of native tools failed\n";
    return !1;
  }

  return 1;
}

sub BuildTestExecutables($$)
{
  my ($Impacts, $Bits) = @_;

  my (@BuildDirs, @TestExes);
  foreach my $TestInfo (values %{$Impacts->{Tests}})
  {
    push @BuildDirs, $TestInfo->{Path};
    my $TestExe = "$TestInfo->{Path}/$TestInfo->{ExeBase}.exe";
    push @TestExes, $TestExe;
    unlink("$DataDir/build-mingw$Bits/$TestExe"); # Ignore errors
  }

  InfoMsg "\nBuilding the $Bits-bit test executable(s)\n";
  system("( cd $DataDir/build-mingw$Bits && set -x && " .
         "  time make -j$ncpus ". join(" ", sort @BuildDirs) .
         ") >>$LogDir/Build.log 2>&1");
  if ($? != 0)
  {
    LogMsg "Rebuild of $Bits-bit crossbuild failed\n";
    return !1;
  }

  my $Success = 1;
  foreach my $TestExe (@TestExes)
  {
    if (!-f "$DataDir/build-mingw$Bits/$TestExe")
    {
      LogMsg "Make didn't produce a $TestExe file\n";
      $Success = undef;
    }
  }

  return $Success;
}

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

# Start with a clean logfile
unlink("$LogDir/Build.log");

my ($PatchFile, $BitIndicators);
if (@ARGV == 2)
{
  ($PatchFile, $BitIndicators) = @ARGV;
}
else
{
  # FIXME Remove support for the legacy parameters
  my ($_PatchType, $_BaseName);
  ($PatchFile, $_PatchType, $_BaseName, $BitIndicators) = @ARGV;
}
if (! $PatchFile || !$BitIndicators)
{
  FatalError "Usage: Build.pl <patchfile> <bits>\n";
}

# Untaint parameters
if ($PatchFile =~ m/^([\w_.\-]+)$/)
{
  $PatchFile = "$DataDir/staging/$1";
  if (! -r $PatchFile)
  {
    FatalError "Patch file $PatchFile not readable\n";
  }
}
else
{
  FatalError "Invalid patch file $PatchFile\n";
}

my ($Run32, $Run64);
if ($BitIndicators =~ m/^([\d,]+)$/)
{
  foreach my $BitsValue (split /,/, $1)
  {
    if ($BitsValue eq "32")
    {
      $Run32 = 1;
    }
    elsif ($BitsValue eq "64")
    {
      $Run64 = 1;
    }
    else
    {
      FatalError "Invalid number of bits $BitsValue\n";
    }
  }
  if (!$Run32 && !$Run64)
  {
    FatalError "Specify at least one of 32 or 64 bits\n";
  }
}
else
{
  FatalError "Invalid number of bits $BitIndicators\n";
}

my $Impacts = ApplyPatch($PatchFile);
exit(1) if (!$Impacts);

CountCPUs();

if (!BuildNative())
{
  exit(1);
}
if ($Run32 && !BuildTestExecutables($Impacts, 32))
{
  exit(1);
}
if ($Run64 && !BuildTestExecutables($Impacts, 64))
{
  exit(1);
}

LogMsg "ok\n";
exit;

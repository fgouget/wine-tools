#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs the 'build' task in the build machine. Specifically this applies a
# conformance test patch, rebuilds the impacted test and retrieves the
# resulting 32 and 64 bit binaries.
#
# Copyright 2009 Ge van Geldorp
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
    return 0;
  }

  my $Impacts = GetPatchImpact($PatchFile, "nounits");
  if ($Impacts->{Makefiles})
  {
    InfoMsg "Running make_makefiles\n";
    system("( cd $DataDir/wine && set -x && " .
           " ./tools/make_makefiles " .
           ") >> $LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "make_makefiles failed\n";
      return 0;
    }
  }

  if ($Impacts->{Autoconf} && !$Impacts->{HasConfigure})
  {
    InfoMsg "Running autoconf\n";
    system("( cd $DataDir/wine && set -x && " .
           "  autoconf " .
           ") >>$LogDir/Build.log 2>&1");
    if ($? != 0)
    {
       LogMsg "Autoconf failed\n";
       return 0;
    }
  }

  return 1;
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

sub BuildNative()
{
  mkdir "$DataDir/build-native" if (! -d "$DataDir/build-native");
  system("( cd $DataDir/build-native && set -x && " .
         "  time make -j$ncpus __tooldeps__ " .
         ") >>$LogDir/Build.log 2>&1");

  if ($? != 0)
  {
    LogMsg "Build native failed\n";
    return !1;
  }

  return 1;
}

sub BuildTestExecutable($$$)
{
  my ($BaseName, $PatchType, $Bits) = @_;

  my $TestsDir = "$PatchType/$BaseName/tests";
  my $TestExecutable = "$TestsDir/$BaseName";
  if ($PatchType eq "programs")
  {
    $TestExecutable .= ".exe";
  }
  $TestExecutable .= "_test.exe";
  unlink("$DataDir/build-mingw${Bits}/$TestExecutable");

  InfoMsg "Building the $Bits-bit test executable\n";
  system("( cd $DataDir/build-mingw$Bits && set -x && " .
         "  time make -j$ncpus $TestsDir " .
         ") >>$LogDir/Build.log 2>&1");
  if ($? != 0)
  {
    LogMsg "Rebuild of $Bits-bit crossbuild failed\n";
    return !1;
  }
  if (! -f "$DataDir/build-mingw${Bits}/$TestExecutable")
  {
    LogMsg "Make didn't produce a $TestExecutable file\n";
    return !1;
  }

  return 1;
}

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

# Start with clean logfile
unlink("$LogDir/Build.log");

my ($PatchFile, $PatchType, $BaseName, $BitIndicators) = @ARGV;
if (! $PatchFile || ! $PatchType || ! $BaseName || !$BitIndicators)
{
  FatalError "Usage: Build.pl <patchfile> <patchtype> <basename> <bits>\n";
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

if ($PatchType =~ m/^patch(dlls|programs)$/)
{
  $PatchType = $1;
}
else
{
  FatalError "Invalid patch type $PatchType\n";
}

if ($BaseName =~ m/^([\w_.\-]+)$/)
{
  $BaseName = $1;
}
else
{
  FatalError "Invalid DLL base name $BaseName\n";
}

my $Run32 = !1;
my $Run64 = !1;
if ($BitIndicators =~ m/^([\d,]+)$/)
{
  my @Bits = split /,/, $1;
  foreach my $BitsValue (@Bits)
  {
    if ($BitsValue == 32)
    {
      $Run32 = 1;
    }
    elsif ($BitsValue == 64)
    {
      $Run64 = 1;
    }
    else
    {
      FatalError "Invalid number of bits $BitsValue\n";
    }
  }
  if (! $Run32 && ! $Run64)
  {
    FatalError "Specify at least one of 32 or 64 bits\n";
  }
}
else
{
  FatalError "Invalid number of bits $BitIndicators\n";
}

if (!ApplyPatch($PatchFile))
{
  exit(1);
}

CountCPUs();

InfoMsg "Building tools\n";
if (!BuildNative())
{
  exit(1);
}

if ($Run32 && ! BuildTestExecutable($BaseName, $PatchType, 32))
{
  exit(1);
}
if ($Run64 && ! BuildTestExecutable($BaseName, $PatchType, 64))
{
  exit(1);
}

LogMsg "ok\n";
exit;

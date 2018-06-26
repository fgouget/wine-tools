#!/usr/bin/perl
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs the 'build' task in the build machine. Specifically this applies a
# conformance test patch, rebuilds the impacted test and retrieves the
# resulting 32 and 64 bit binaries.
#
# This script does not use tainting (-T) because its whole purpose is to run
# arbitrary user-provided code anyway (in patch form).
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

use warnings;
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
my $Name0 = $0;
$Name0 =~ s+^.*/++;


use WineTestBot::Config;
use WineTestBot::PatchUtils;
use WineTestBot::Utils;


#
# Logging and error handling helpers
#

sub InfoMsg(@)
{
  print @_;
}

sub LogMsg(@)
{
  print "Build: ", @_;
}

sub Error(@)
{
  print STDERR "$Name0:error: ", @_;
}


#
# Build helpers
#

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
  system("cd '$DataDir/wine' && set -x && ".
         "git apply --verbose ". ShQuote($PatchFile) ." && ".
         "git add -A");
  if ($? != 0)
  {
    LogMsg "Patch failed to apply\n";
    return undef;
  }

  my $Impacts = GetPatchImpact($PatchFile, "nounits");
  if ($Impacts->{MakeMakefiles})
  {
    InfoMsg "\nRunning make_makefiles\n";
    system("cd '$DataDir/wine' && set -x && ./tools/make_makefiles");
    if ($? != 0)
    {
      LogMsg "make_makefiles failed\n";
      return undef;
    }
  }

  if ($Impacts->{Autoconf} && !$Impacts->{HasConfigure})
  {
    InfoMsg "\nRunning autoconf\n";
    system("cd '$DataDir/wine' && set -x && autoconf");
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
  system("cd '$DataDir/build-native' && set -x && ".
         "time make -j$ncpus __tooldeps__");
  if ($? != 0)
  {
    LogMsg "Rebuild of native tools failed\n";
    return !1;
  }

  return 1;
}

sub BuildTestExecutables($$$)
{
  my ($Targets, $Impacts, $Bits) = @_;

  return 1 if (!$Targets->{"exe$Bits"});

  my (@BuildDirs, @TestExes);
  foreach my $TestInfo (values %{$Impacts->{Tests}})
  {
    push @BuildDirs, $TestInfo->{Path};
    my $TestExe = "$TestInfo->{Path}/$TestInfo->{ExeBase}.exe";
    push @TestExes, $TestExe;
    unlink("$DataDir/build-mingw$Bits/$TestExe"); # Ignore errors
  }

  InfoMsg "\nBuilding the $Bits-bit test executable(s)\n";
  system("cd '$DataDir/build-mingw$Bits' && set -x && ".
         "time make -j$ncpus ". join(" ", sort @BuildDirs));
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


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

my %AllTargets;
map { $AllTargets{$_} = 1 } qw(exe32 exe64);

my ($Usage, $PatchFile, $TargetList);
my $IgnoreNext = 0; # FIXME Backward compatibility
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg =~ /^patch(?:dlls|programs)$/)
  {
    $IgnoreNext ||= 1; # Ignore this legacy parameter
  }
  elsif ($IgnoreNext == 1)
  {
    $IgnoreNext = 2; # Ignore this legacy parameter
  }
  elsif ($Arg =~ /^(?:-\?|-h|--help)$/)
  {
    $Usage = 0;
    last;
  }
  elsif ($Arg =~ /^-/)
  {
    Error "unknown option '$Arg'\n";
    $Usage = 2;
    last;
  }
  elsif (!defined $PatchFile)
  {
    if (IsValidFileName($Arg))
    {
      $PatchFile = "$DataDir/staging/$Arg";
      if (!-r $PatchFile)
      {
        Error "patch file '$Arg' is not readable\n";
        $Usage = 2;
      }
    }
    else
    {
      Error "the patch filename '$Arg' contains invalid characters\n";
      $Usage = 2;
      last;
    }
  }
  elsif (!defined $TargetList)
  {
    $TargetList = $Arg;
  }
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check and untaint parameters
my $Targets;
if (!defined $Usage)
{
  if (!defined $PatchFile)
  {
    Error "you must specify a patch to apply\n";
    $Usage = 2;
  }

  $TargetList = join(",", keys %AllTargets) if (!defined $TargetList);
  foreach my $Target (split /,/, $TargetList)
  {
    $Target = "exe$1" if ($Target =~ /^(32|64)$/);
    if (!$AllTargets{$Target})
    {
      Error "invalid target name $Target\n";
      $Usage = 2;
      last;
    }
    $Targets->{$Target} = 1;
  }
}
if (defined $Usage)
{
  if ($Usage)
  {
    Error "try '$Name0 --help' for more information\n";
    exit $Usage;
  }
  print "Usage: $Name0 [--help] PATCHFILE TARGETS\n";
  print "\n";
  print "Applies the specified patch and rebuilds the Wine test executables.\n";
  print "\n";
  print "Where:\n";
  print "  PATCHFILE Is the staging file containing the patch to build.\n";
  print "  TARGETS   Is a comma-separated list of build targets. By default every\n";
  print "            target is run.\n";
  print "            - exe32: Rebuild the 32 bit Windows test executables.\n";
  print "            - exe64: Rebuild the 64 bit Windows test executables.\n";
  print "  --help    Shows this usage message.\n";
  exit 0;
}

if ($DataDir =~ /'/)
{
    LogMsg "The install path contains invalid characters\n";
    exit(1);
}


#
# Run the builds
#

CountCPUs();

my $Impacts = ApplyPatch($PatchFile);

if (!$Impacts or
    ($Impacts->{WineBuild} and !BuildNative()) or
    !BuildTestExecutables($Targets, $Impacts, 32) or
    !BuildTestExecutables($Targets, $Impacts, 64))
{
  exit(1);
}

LogMsg "ok\n";
exit;

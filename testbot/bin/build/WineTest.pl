#!/usr/bin/perl
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Applies the patch and rebuilds Wine.
#
# This script does not use tainting (-T) because its whole purpose is to run
# arbitrary user-provided code anyway.
#
# Copyright 2018 Francois Gouget
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
  print "Task: ", @_;
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

sub BuildWine($$)
{
  my ($Targets, $Build) = @_;

  return 1 if (!$Targets->{$Build});

  InfoMsg "\nRebuilding the $Build Wine\n";
  system("cd '$DataDir/build-$Build' && set -x && ".
         "time make -j$ncpus");
  if ($? != 0)
  {
    LogMsg "The $Build build failed\n";
    return !1;
  }

  return 1;
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

my %AllTargets;
map { $AllTargets{$_} = 1 } qw(win32 wow32 wow64);

my ($Usage, $TargetList, $Action, $FileName);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg =~ /^(?:-\?|-h|--help)$/)
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
  elsif (!defined $TargetList)
  {
    $TargetList = $Arg;
  }
  elsif (!defined $Action)
  {
    $Action = $Arg;
  }
  elsif (!defined $FileName)
  {
    if (IsValidFileName($Arg))
    {
      $FileName = "$DataDir/staging/$Arg";
      if (!-r $FileName)
      {
        Error "'$Arg' is not readable\n";
        $Usage = 2;
      }
    }
    else
    {
      Error "invalid file name '$Arg'\n";
      $Usage = 2;
      last;
    }
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
  if (defined $TargetList)
  {
    foreach my $Target (split /,/, $TargetList)
    {
      if (!$AllTargets{$Target})
      {
        Error "invalid target name $Target\n";
        $Usage = 2;
      }
      $Targets->{$Target} = 1;
    }
  }
  else
  {
    Error "specify at least one target\n";
    $Usage = 2;
  }

  if (!defined $Action)
  {
    Error "you must specify the action to perform\n";
    $Usage = 2;
  }
  elsif ($Action ne "build")
  {
    Error "invalid '$Action' action\n";
    $Usage = 2;
  }

  if (!defined $FileName and $Action eq "build")
  {
    Error "you must provide a patch file\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
  print "Usage: $Name0 [--help] TARGETS build PATCH\n";
  print "\n";
  print "Applies the specified patch and rebuilds Wine.\n";
  print "\n";
  print "Where:\n";
  print "  TARGETS   Is a comma-separated list of targets for the build.\n";
  print "            - win32: The regular 32 bit Wine build.\n";
  print "            - wow32: The 32 bit WoW Wine build.\n";
  print "            - wow64: The 64 bit WoW Wine build.\n";
  print "  build     Verify that the patch compiles.\n";
  print "  PATCH     Is the staging file containing the patch to test.\n";
  print "  --help    Shows this usage message.\n";
  exit $Usage;
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

my $Impacts = ApplyPatch($FileName);
exit(1) if (!$Impacts or
            !BuildWine($Targets, "win32") or
            !BuildWine($Targets, "wow64") or
            !BuildWine($Targets, "wow32"));

LogMsg "ok\n";
exit;

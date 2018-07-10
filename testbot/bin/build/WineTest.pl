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
# Test helpers
#

# See also WineReconfig.pl
sub SetupWineEnvironment($)
{
  my ($Build) = @_;

  $ENV{WINEPREFIX} = "$DataDir/wineprefix-$Build";
  $ENV{DISPLAY} ||= ":0.0";
}

# See also WineReconfig.pl
sub RunWine($$$)
{
  my ($Build, $Cmd, $CmdArgs) = @_;

  my $Magic = `cd '$DataDir/build-$Build' && file $Cmd`;
  my $Wine = ($Magic =~ /ELF 64/ ? "./wine64" : "./wine");
  return system("cd '$DataDir/build-$Build' && set -x && ".
                "time $Wine $Cmd $CmdArgs");
}

sub DailyWineTest($$$$)
{
  my ($Targets, $Build, $BaseTag, $Args) = @_;

  return 1 if (!$Targets->{$Build});

  InfoMsg "\nRunning WineTest in the $Build Wine\n";
  SetupWineEnvironment($Build);

  # Run WineTest. Ignore the exit code since it returns non-zero whenever
  # there are test failures.
  RunWine($Build, "./programs/winetest/winetest.exe.so",
          "-c -o '../$Build.report' -t $BaseTag-$Build ". ShArgv2Cmd(@$Args));
  if (!-f "$Build.report")
  {
    LogMsg "WineTest did not produce a report file\n";
    return 0;
  }

  # Send the report to the website
  if ($Targets->{submit} and
      RunWine($Build, "./programs/winetest/winetest.exe.so",
              "-c -s '../$Build.report'"))
  {
    LogMsg "WineTest failed to send the $Build report\n";
    # Soldier on in case it's just a network issue
  }

  return 1;
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

my %AllTargets;
map { $AllTargets{$_} = 1 } qw(win32 wow32 wow64 submit);

my ($Usage, $TargetList, $Action, $FileName, $BaseTag);
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
  elsif (($Action || "") eq "winetest")
  {
    $BaseTag = $Arg;
    # The remaining arguments are meant for WineTest
    last;
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
      Error "the '$Arg' filename contains invalid characters\n";
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
  elsif ($Action eq "winetest")
  {
    if (!defined $BaseTag)
    {
      Error "you must specify a base tag for WineTest\n";
      $Usage = 2;
    }
    elsif ($BaseTag =~ m/^([\w_.\-]+)$/)
    {
      $BaseTag = $1;
    }
    else
    {
      Error "invalid WineTest base tag '$BaseTag'\n";
      $Usage = 2;
    }
  }
  elsif ($Action ne "build")
  {
    Error "invalid '$Action' action\n";
    $Usage = 2;
  }

  if (!defined $FileName and ($Action || "") eq "build")
  {
    Error "you must provide a patch to test\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
  print "Usage: $Name0 [--help] TARGETS build PATCH\n";
  print "or     $Name0 [--help] TARGETS winetest BASETAG ARGS\n";
  print "\n";
  print "Tests the specified patch or runs WineTest in Wine.\n";
  print "\n";
  print "Where:\n";
  print "  TARGETS   Is a comma-separated list of targets for the specified action.\n";
  print "            - win32: The regular 32 bit Wine build.\n";
  print "            - wow32: The 32 bit WoW Wine build.\n";
  print "            - wow64: The 64 bit WoW Wine build.\n";
  print "            - submit: Send the WineTest result to the website.\n";
  print "  build     Verify that the patch compiles.\n";
  print "  PATCH     Is the staging file containing the patch to test.\n";
  print "  winetest  Run WineTest and submit the result to the website if the submit\n";
  print "            task was specified.\n";
  print "  BASETAG   Is the tag for this WineTest run. Note that the build type is\n";
  print "            automatically added to this tag.\n";
  print "  ARGS      The WineTest arguments.\n";
  print "  --help    Shows this usage message.\n";
  exit $Usage;
}

if ($DataDir =~ /'/)
{
    LogMsg "The install path contains invalid characters\n";
    exit(1);
}


#
# Run the builds and tests
#

# Clean up old reports
map { unlink("$_.report") } keys %AllTargets;

CountCPUs();

if ($Action eq "build")
{
  my $Impacts = ApplyPatch($FileName);
  exit(1) if (!$Impacts or
              !BuildWine($Targets, "win32") or
              !BuildWine($Targets, "wow64") or
              !BuildWine($Targets, "wow32"));
}
elsif ($Action eq "winetest")
{
  exit(1) if (!DailyWineTest($Targets, "win32", $BaseTag, \@ARGV) or
              !DailyWineTest($Targets, "wow64", $BaseTag, \@ARGV) or
              !DailyWineTest($Targets, "wow32", $BaseTag, \@ARGV));
}

LogMsg "ok\n";
exit;

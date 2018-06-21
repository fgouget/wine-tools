#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Updates the Wine source from Git and rebuilds it.
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


#
# Logging and error handling helpers
#

sub InfoMsg(@)
{
  print @_;
}

sub LogMsg(@)
{
  print "Reconfig: ", @_;
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

sub BuildTestAgentd()
{
  # If testagentd already exists it's likely already running
  # so don't rebuild it.
  if (! -x "$BinDir/build/testagentd")
  {
    InfoMsg "\nBuilding the native testagentd\n";
    system("cd '$::RootDir/src/testagentd' && set -x && ".
           "time make -j$ncpus build");
    if ($? != 0)
    {
      LogMsg "Build testagentd failed\n";
      return !1;
    }
  }

  return 1;
}

sub GitPull($)
{
  my ($Targets) = @_;
  return 1 if (!$Targets->{update});

  InfoMsg "\nUpdating the Wine source\n";
  system("cd '$DataDir/wine' && git pull");
  if ($? != 0)
  {
    LogMsg "Git pull failed\n";
    return !1;
  }

  my $ErrMessage = UpdateWineData("$DataDir/wine");
  if ($ErrMessage)
  {
    LogMsg "$ErrMessage\n";
    return !1;
  }

  return 1;
}

sub BuildWine($$$$)
{
  my ($Targets, $NoRm, $Build, $Extras) = @_;

  return 1 if (!$Targets->{$Build});
  mkdir "$DataDir/build-$Build" if (!-d "$DataDir/build-$Build");

  # If $NoRm is not set, rebuild from scratch to make sure cruft will not
  # accumulate
  InfoMsg "\nRebuilding the $Build Wine\n";
  system("cd '$DataDir/build-$Build' && set -x && ".
         ($NoRm ? "" : "rm -rf * && ") .
         "time ../wine/configure $Extras --disable-winetest && ".
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
map { $AllTargets{$_} = 1 } qw(update win32 wow32 wow64);

my ($Usage, $TargetList, $NoRm);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--no-rm")
  {
    $NoRm = 1;
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
  $TargetList = join(",", keys %AllTargets) if (!defined $TargetList);
  foreach my $Target (split /,/, $TargetList)
  {
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
  print "Usage: $Name0 [--no-rm] [--help] [TARGETS]\n";
  print "\n";
  print "Performs all the tasks needed for the host to be ready to test new patches: update the Wine source and rebuild the Wine binaries.\n";
  print "\n";
  print "Where:\n";
  print "  TARGETS   Is a comma-separated list of targets to process. By default all\n";
  print "            targets are processed.\n";
  print "            - update: Update Wine's source code.\n";
  print "            - win32: Rebuild the regular 32 bit Wine.\n";
  print "            - wow32: Rebuild the 32 bit WoW Wine.\n";
  print "            - wow64: Rebuild the 64 bit WoW Wine.\n";
  print "  --no-rm   Don't rebuild from scratch.\n";
  print "  --help    Shows this usage message.\n";
  exit 0;
}

if (! -d "$DataDir/staging" and ! mkdir "$DataDir/staging")
{
    LogMsg "Unable to create '$DataDir/staging': $!\n";
    exit(1);
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

if (!BuildTestAgentd() ||
    !GitPull($Targets) ||
    !BuildWine($Targets, $NoRm, "win32", "") ||
    !BuildWine($Targets, $NoRm, "wow64", "--enable-win64") ||
    !BuildWine($Targets, $NoRm, "wow32", "--with-wine64='$DataDir/build-wow64'"))
{
  exit(1);
}

LogMsg "ok\n";
exit;

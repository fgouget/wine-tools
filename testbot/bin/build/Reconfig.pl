#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs the 'reconfig' task in the build machine. Specifically this updates
# the build machine's Wine repository, re-runs configure, and rebuilds the
# 32 and 64 bit winetest binaries.
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

  InfoMsg "\nRebuilding the Windows TestAgentd\n";
  system("cd '$::RootDir/src/testagentd' && set -x && ".
         "time make -j$ncpus iso");
  if ($? != 0)
  {
    LogMsg "Build winetestbot.iso failed\n";
    return !1;
  }

  return 1;
}

sub BuildTestLauncher()
{
  InfoMsg "\nRebuilding TestLauncher\n";
  system("cd '$::RootDir/src/TestLauncher' && set -x && ".
         "time make -j$ncpus");
  if ($? != 0)
  {
    LogMsg "Build TestLauncher failed\n";
    return !1;
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

sub BuildNative($$)
{
  my ($Targets, $NoRm) = @_;

  return 1 if (!$Targets->{native});
  mkdir "$DataDir/build-native" if (! -d "$DataDir/build-native");

  # Rebuild from scratch to make sure cruft will not accumulate
  InfoMsg "\nRebuilding native tools\n";
  system("cd '$DataDir/build-native' && set -x && ".
         ($NoRm ? "" : "rm -rf * && ") .
         "time ../wine/configure --enable-win64 --without-x --without-freetype --disable-winetest && ".
         "time make -j$ncpus __tooldeps__");

  if ($? != 0)
  {
    LogMsg "Build native failed\n";
    return !1;
  }

  return 1;
}

sub BuildCross($$$)
{
  my ($Targets, $NoRm, $Bits) = @_;

  return 1 if (!$Targets->{"exe$Bits"});
  mkdir "$DataDir/build-mingw$Bits" if (!-d "$DataDir/build-mingw$Bits");

  # Rebuild from scratch to make sure cruft will not accumulate
  InfoMsg "\nRebuilding the $Bits-bit test executables\n";
  my $Host = ($Bits == 64 ? "x86_64-w64-mingw32" : "i686-w64-mingw32");
  system("cd '$DataDir/build-mingw$Bits' && set -x && ".
         ($NoRm ? "" : "rm -rf * && ") .
         "time ../wine/configure --host=$Host --with-wine-tools=../build-native --without-x --without-freetype --disable-winetest && ".
         "time make -j$ncpus buildtests");
  if ($? != 0)
  {
    LogMsg "Build cross ($Bits bits) failed\n";
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
map { $AllTargets{$_} = 1 } qw(update native exe32 exe64);

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
  print "Updates Wine to the latest version and recompiles it so the host is ready to build executables for the Windows tests.\n";
  print "\n";
  print "Where:\n";
  print "  TARGETS   Is a comma-separated list of reconfiguration targets. By default\n";
  print "            every target is run.\n";
  print "            - update: Update Wine's source code.\n";
  print "            - native: Rebuild the native Wine tools.\n";
  print "            - exe32: Rebuild the 32 bit Windows test executables.\n";
  print "            - exe64: Rebuild the 64 bit Windows test executables.\n";
  print "  --no-rm   Don't rebuild from scratch.\n";
  print "  --help    Shows this usage message.\n";
  exit 0;
}

if ($DataDir =~ /'/)
{
    LogMsg "The install path contains invalid characters\n";
    exit(1);
}
if (! -d "$DataDir/staging" and ! mkdir "$DataDir/staging")
{
    LogMsg "Unable to create '$DataDir/staging': $!\n";
    exit(1);
}


#
# Run the builds
#

CountCPUs();

if (!BuildTestAgentd() or
    !BuildTestLauncher() or
    !GitPull($Targets) or
    !BuildNative($Targets, $NoRm) or
    !BuildCross($Targets, $NoRm, 32) or
    !BuildCross($Targets, $NoRm, 64))
{
  exit(1);
}

LogMsg "ok\n";
exit;

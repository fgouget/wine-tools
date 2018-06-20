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

use WineTestBot::Config;
use WineTestBot::PatchUtils;


sub InfoMsg(@)
{
  print @_;
}

sub LogMsg(@)
{
  print "Reconfig: ", @_;
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

sub BuildTestAgentd()
{
  # If testagentd already exists it's likely already running
  # so don't rebuild it.
  if (! -x "$BinDir/build/testagentd")
  {
    InfoMsg "\nBuilding the native testagentd\n";
    system("cd $::RootDir/src/testagentd && set -x && ".
           "time make -j$ncpus build");
    if ($? != 0)
    {
      LogMsg "Build testagentd failed\n";
      return !1;
    }
  }

  InfoMsg "\nRebuilding the Windows TestAgentd\n";
  system("cd $::RootDir/src/testagentd && set -x && ".
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
  system("cd $::RootDir/src/TestLauncher && set -x && ".
         "time make -j$ncpus");
  if ($? != 0)
  {
    LogMsg "Build TestLauncher failed\n";
    return !1;
  }

  return 1;
}

sub GitPull()
{
  InfoMsg "\nUpdating the Wine source\n";
  system("cd $DataDir/wine && git pull");
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

sub BuildNative()
{
  mkdir "$DataDir/build-native" if (! -d "$DataDir/build-native");

  # Rebuild from scratch to make sure cruft will not accumulate
  InfoMsg "\nRebuilding native tools\n";
  system("cd $DataDir/build-native && set -x && ".
         "rm -rf * && ".
         "time ../wine/configure --enable-win64 --without-x --without-freetype --disable-winetest && ".
         "time make -j$ncpus __tooldeps__");

  if ($? != 0)
  {
    LogMsg "Build native failed\n";
    return !1;
  }

  return 1;
}

sub BuildCross($)
{
  my ($Bits) = @_;

  my $Host = ($Bits == 64 ? "x86_64-w64-mingw32" : "i686-w64-mingw32");
  mkdir "$DataDir/build-mingw$Bits" if (! -d "$DataDir/build-mingw$Bits");

  # Rebuild from scratch to make sure cruft will not accumulate
  InfoMsg "\nRebuilding the $Bits-bit test executables\n";
  system("cd $DataDir/build-mingw$Bits && set -x && ".
         "rm -rf * && ".
         "time ../wine/configure --host=$Host --with-wine-tools=../build-native --without-x --without-freetype --disable-winetest && ".
         "time make -j$ncpus buildtests");
  if ($? != 0)
  {
    LogMsg "Build cross ($Bits bits) failed\n";
    return !1;
  }

  return 1;
}

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

if (! -d "$DataDir/staging" and ! mkdir "$DataDir/staging")
{
    LogMsg "Unable to create '$DataDir/staging': $!\n";
    exit(1);
}

CountCPUs();

if (!BuildTestAgentd() ||
    !BuildTestLauncher() ||
    !GitPull() ||
    !BuildNative() ||
    !BuildCross(32) ||
    !BuildCross(64))
{
  exit(1);
}

LogMsg "ok\n";
exit;

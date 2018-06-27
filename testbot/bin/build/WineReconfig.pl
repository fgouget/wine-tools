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


use Digest::SHA;
use File::Path;

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

  return 1 if (!$Targets->{build} or !$Targets->{$Build});
  mkdir "$DataDir/build-$Build" if (!-d "$DataDir/build-$Build");

  # If $NoRm is not set, rebuild from scratch to make sure cruft will not
  # accumulate
  InfoMsg "\nRebuilding the $Build Wine\n";
  system("cd '$DataDir/build-$Build' && set -x && ".
         ($NoRm ? "" : "rm -rf * && ") .
         "time ../wine/configure $Extras && ".
         "time make -j$ncpus");
  if ($? != 0)
  {
    LogMsg "The $Build build failed\n";
    return !1;
  }

  return 1;
}


#
# WinePrefix helpers
#

sub VerifyAddOn($$)
{
  my ($AddOn, $Arch) = @_;

  my $Sha256 = Digest::SHA->new(256);
  eval { $Sha256->addfile("$DataDir/$AddOn->{name}/$AddOn->{filename}") };
  return "$@" if ($@);

  my $Checksum = $Sha256->hexdigest();
  return undef if ($Checksum eq $AddOn->{$Arch});
  return "Bad checksum for '$AddOn->{filename}'";
}

sub UpdateAddOn($$$)
{
  my ($AddOn, $Name, $Arch) = @_;

  if (!defined $AddOn)
  {
    LogMsg "Could not get information on the $Name addon\n";
    return 0;
  }
  if (!$AddOn->{version})
  {
    LogMsg "Could not get the $Name version\n";
    return 0;
  }
  if (!$AddOn->{$Arch})
  {
    LogMsg "Could not get the $Name $Arch checksum\n";
    return 0;
  }

  $AddOn->{filename} = "wine". ($Name eq "gecko" ? "_" : "-") .
                       "$Name-$AddOn->{version}".
                       ($Arch eq "" ? "" : "-$Arch") .".msi";
  return 1 if (!VerifyAddOn($AddOn, $Arch));

  InfoMsg "Downloading $AddOn->{filename}\n";
  mkdir "$DataDir/$Name";

  my $Url="http://dl.winehq.org/wine/wine-$Name/$AddOn->{version}/$AddOn->{filename}";
  for (1..3)
  {
    system("cd '$DataDir/$Name' && set -x && ".
           "wget --no-verbose -O- '$Url' >'$AddOn->{filename}'");
    last if ($? == 0);
  }
  my $ErrMessage = VerifyAddOn($AddOn, $Arch);
  return 1 if (!defined $ErrMessage);
  LogMsg "$ErrMessage\n";
  return 0;
}

sub UpdateAddOns($)
{
  my ($Targets) = @_;
  return 1 if (!$Targets->{addons});

  my %AddOns;
  if (open(my $fh, "<", "$DataDir/wine/dlls/appwiz.cpl/addons.c"))
  {
    my $Arch = "";
    while (my $Line= <$fh>)
    {
      if ($Line =~ /^\s*#\s*define\s+ARCH_STRING\s+"([^"]+)"/)
      {
        $Arch = $1;
      }
      elsif ($Line =~ /^\s*#\s*define\s*(GECKO|MONO)_VERSION\s*"([^"]+)"/)
      {
        my ($AddOn, $Version) = ($1, $2);
        $AddOn =~ tr/A-Z/a-z/;
        $AddOns{$AddOn}->{name} = $AddOn;
        $AddOns{$AddOn}->{version} = $Version;
      }
      elsif ($Line =~ /^\s*#\s*define\s*(GECKO|MONO)_SHA\s*"([^"]+)"/)
      {
        my ($AddOn, $Checksum) = ($1, $2);
        $AddOn =~ tr/A-Z/a-z/;
        $AddOns{$AddOn}->{$Arch} = $Checksum;
        $Arch = "";
      }
    }
    close($fh);
  }
  else
  {
    LogMsg "Could not open 'wine/dlls/appwiz.cpl/addons.c': $!\n";
    return 0;
  }

  return UpdateAddOn($AddOns{gecko}, "gecko", "x86") &&
         UpdateAddOn($AddOns{gecko}, "gecko", "x86_64") &&
         UpdateAddOn($AddOns{mono},  "mono",  "");
}

# See also WineTest.pl
sub SetupWineEnvironment($)
{
  my ($Build) = @_;

  $ENV{WINEPREFIX} = "$DataDir/wineprefix-$Build";
  $ENV{DISPLAY} ||= ":0.0";
}

# See also WineTest.pl
sub RunWine($$$)
{
  my ($Build, $Cmd, $CmdArgs) = @_;

  my $Magic = `cd '$DataDir/build-$Build' && file $Cmd`;
  my $Wine = ($Magic =~ /ELF 64/ ? "./wine64" : "./wine");
  return system("cd '$DataDir/build-$Build' && set -x && ".
                "time $Wine $Cmd $CmdArgs");
}

# Setup a brand new WinePrefix ready for use for testing.
# This way we do it once instead of doing it for every test, thus saving
# time. Note that this requires using a different wineprefix for each build.
sub NewWinePrefix($$)
{
  my ($Targets, $Build) = @_;

  return 1 if (!$Targets->{wineprefix} or !$Targets->{$Build});

  InfoMsg "\nRecreating the $Build wineprefix\n";
  SetupWineEnvironment($Build);
  rmtree($ENV{WINEPREFIX});

  # Crash dialogs cause delays so disable them
  if (RunWine($Build, "./programs/reg/reg.exe.so", "ADD HKCU\\\\Software\\\\Wine\\\\WineDbg /v ShowCrashDialog /t REG_DWORD /d 0"))
  {
    LogMsg "Failed to disable the $Build build crash dialogs: $!\n";
    return 0;
  }

  # Ensure the WinePrefix has been fully created before updating the snapshot
  system("cd '$DataDir/build-$Build' && ./server/wineserver -w");

  return 1;
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

my %AllTargets;
map { $AllTargets{$_} = 1 } qw(update addons build wineprefix win32 wow32 wow64);

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
  print "Performs all the tasks needed for the host to be ready to test new patches: update the Wine source and addons, and rebuild the Wine binaries.\n";
  print "\n";
  print "Where:\n";
  print "  TARGETS   Is a comma-separated list of targets to process. By default all\n";
  print "            targets are processed.\n";
  print "            - update: Update Wine's source code.\n";
  print "            - build: Update the Wine builds.\n";
  print "            - addons: Update the Gecko and Mono Wine addons.\n";
  print "            - wineprefix: Update the wineprefixes.\n";
  print "            - win32: Apply the above to the regular 32 bit Wine.\n";
  print "            - wow32: Apply the above to the 32 bit WoW Wine.\n";
  print "            - wow64: Apply the above to the 64 bit WoW Wine.\n";
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
# Run the builds and/or tests
#

CountCPUs();

if (!BuildTestAgentd() or
    !GitPull($Targets) or
    !UpdateAddOns($Targets) or
    !BuildWine($Targets, $NoRm, "win32", "") or
    !BuildWine($Targets, $NoRm, "wow64", "--enable-win64") or
    !BuildWine($Targets, $NoRm, "wow32", "--with-wine64='$DataDir/build-wow64'") or
    !NewWinePrefix($Targets, "win32") or
    # The wow32 and wow64 wineprefixes:
    # - Are essentially identical.
    # - Must be created after both WoW builds have been updated.
    # - Make it possible to run the wow32 and wow64 tests in separate prefixes,
    #   thus ensuring they don't interfere with each other.
    !NewWinePrefix($Targets, "wow64") or
    !NewWinePrefix($Targets, "wow32"))
{
  exit(1);
}

LogMsg "ok\n";
exit;

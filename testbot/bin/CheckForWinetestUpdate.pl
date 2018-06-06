#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Checks if a new winetest binary is available on http://test.winehq.org/data/.
# If so, triggers an update of the build VM to the latest Wine source and
# runs the full test suite on the standard Windows test VMs.
#
# Copyright 2009 Ge van Geldorp
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
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
}
my $Name0 = $0;
$Name0 =~ s+^.*/++;

use File::Basename;
use File::Compare;
use File::Copy;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Response;
use HTTP::Status;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::Users;
use WineTestBot::Log;
use WineTestBot::Utils;
use WineTestBot::VMs;
use WineTestBot::Engine::Notify;


my %WineTestUrls = (
    32 => "http://test.winehq.org/builds/winetest-latest.exe",
    64 => "http://test.winehq.org/builds/winetest64-latest.exe"
);

my %TaskTypes = (build => 1, base32 => 1, winetest32 => 1, all64 => 1);


my $Debug;
sub Debug(@)
{
  print STDERR @_ if ($Debug);
}

my $LogOnly;
sub Error(@)
{
  print STDERR "$Name0:error: ", @_ if (!$LogOnly);
  LogMsg @_;
}


=pod
=over 12

=item C<UpdateWineTest()>

Downloads the latest WineTest executable.

Returns 1 if the executable was updated, 0 if it was not, and -1 if an
error occurred.

=back
=cut

sub UpdateWineTest($$)
{
  my ($OptCreate, $Bits) = @_;

  my $BitsSuffix = ($Bits == 64 ? "64" : "");
  my $LatestBaseName = "winetest${BitsSuffix}-latest.exe";
  my $LatestFileName = "$DataDir/latest/$LatestBaseName";
  if ($OptCreate)
  {
    return (1, $LatestBaseName) if (-r $LatestFileName);
    Debug("$LatestBaseName is missing\n");
  }

  # See if the online WineTest executable is newer
  my $UA = LWP::UserAgent->new();
  $UA->agent("WineTestBot");
  my $Request = HTTP::Request->new(GET => $WineTestUrls{$Bits});
  if (-r $LatestFileName)
  {
    my $Since = gmtime((stat $LatestFileName)[9]);
    $Request->header("If-Modified-Since" => "$Since GMT");
  }
  Debug("Checking $WineTestUrls{$Bits}\n");
  my $Response = $UA->request($Request);
  if ($Response->code == RC_NOT_MODIFIED)
  {
    Debug("$LatestBaseName is already up to date\n");
    return (0, $LatestBaseName); # Already up to date
  }
  if ($Response->code != RC_OK)
  {
    Error "Unexpected HTTP response code ", $Response->code, "\n";
    return (-1, undef);
  }

  # Download the WineTest executable
  Debug("Downloading $LatestBaseName\n");
  umask 002;
  mkdir "$DataDir/staging";
  my ($fh, $StagingFileName) = OpenNewFile("$DataDir/staging", "_$LatestBaseName");
  if (!$fh)
  {
    Error "Could not create staging file: $!\n";
    return (-1, undef);
  }
  print $fh $Response->decoded_content();
  close($fh);

  if (-r $LatestFileName and compare($StagingFileName, $LatestFileName) == 0)
  {
    Debug("$LatestBaseName did not change\n");
    unlink($StagingFileName);
    return (0, $LatestBaseName); # No change after all
  }

  # Save the WineTest executable to the latest directory for the next round
  mkdir "$DataDir/latest";
  if (!move($StagingFileName, $LatestFileName))
  {
    Error "Could not move '$StagingFileName' to '$LatestFileName': $!\n";
    unlink($StagingFileName);
    return (-1, undef);
  }
  utime time, $Response->last_modified, $LatestFileName;

  return (1, $LatestBaseName);
}

sub AddJob($$$)
{
  my ($BaseJob, $LatestBaseName, $Bits) = @_;

  my $Remarks = ($Bits == 64 ? "64-bit" : $BaseJob ? "base" : "other");
  $Remarks = "WineTest: $Remarks VMs";
  Debug("Creating the '$Remarks' job\n");

  my $VMs = CreateVMs();
  if ($Bits == 64)
  {
    $VMs->AddFilter("Type", ["win64"]);
    $VMs->AddFilter("Role", ["base", "winetest"]);
  }
  elsif ($BaseJob)
  {
    $VMs->AddFilter("Type", ["win32", "win64"]);
    $VMs->AddFilter("Role", ["base"]);
  }
  else
  {
    $VMs->AddFilter("Type", ["win32", "win64"]);
    $VMs->AddFilter("Role", ["winetest"]);
  }
  if ($VMs->GetItemsCount() == 0)
  {
    # There is nothing to do
    Debug("  Found no VM\n");
    return 1;
  }

  # First create a new job
  my $Jobs = CreateJobs();
  my $NewJob = $Jobs->Add();
  $NewJob->User(GetBatchUser());
  $NewJob->Priority($BaseJob && $Bits == 32 ? 8 : 9);
  $NewJob->Remarks($Remarks);

  # Add a step to the job
  my $Steps = $NewJob->Steps;
  my $NewStep = $Steps->Add();
  my $BitsSuffix = ($Bits == 64 ? "64" : "");
  $NewStep->Type("suite");
  $NewStep->FileName($LatestBaseName);
  $NewStep->FileType($Bits == 64 ? "exe64" : "exe32");
  $NewStep->InStaging(!1);

  # Add a task for each VM
  my $Tasks = $NewStep->Tasks;
  foreach my $VMKey (@{$VMs->SortKeysBySortOrder($VMs->GetKeys())})
  {
    Debug("  $VMKey\n");
    my $Task = $Tasks->Add();
    $Task->VM($VMs->GetItem($VMKey));
    $Task->Timeout($SuiteTimeout);
  }

  # Save it all
  my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    LogMsg "Failed to save the $LatestBaseName job: $ErrMessage\n";
    return 0;
  }

  # Stage the test file so it can be picked up by the job
  if (!link("$DataDir/latest/$LatestBaseName",
            "$DataDir/staging/job". $NewJob->Id ."_$LatestBaseName"))
  {
    Error "Failed to stage $LatestBaseName: $!\n";
    return 0;
  }

  # Switch Status to staging to indicate we are done setting up the job
  $NewJob->Status("staging");
  ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    Error "Failed to save the $LatestBaseName job (staging): $ErrMessage\n";
    return 0;
  }

  return 1;
}

sub AddReconfigJob()
{
  my $Remarks = "Update Wine to latest git";
  Debug("Creating the '$Remarks' job\n");

  # First create a new job
  my $Jobs = CreateJobs();
  my $NewJob = $Jobs->Add();
  $NewJob->User(GetBatchUser());
  $NewJob->Priority(3);
  $NewJob->Remarks($Remarks);

  # Add a step to the job
  my $Steps = $NewJob->Steps;
  my $NewStep = $Steps->Add();
  $NewStep->Type("reconfig");
  $NewStep->FileType("none");
  $NewStep->InStaging(!1);

  # Add a task for the build VM
  my $VMs = CreateVMs();
  $VMs->AddFilter("Type", ["build"]);
  $VMs->AddFilter("Role", ["base"]);
  my $BuildVM = ${$VMs->GetItems()}[0];
  Debug("  ", $BuildVM->GetKey(), "\n");
  my $Task = $NewStep->Tasks->Add();
  $Task->VM($BuildVM);
  $Task->Timeout($ReconfigTimeout);

  # Save it all
  my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    Error "Failed to save the Reconfig job: $ErrMessage\n";
    return 0;
  }

  # Switch Status to staging to indicate we are done setting up the job
  $NewJob->Status("staging");
  ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    Error "Failed to save the Reconfig job (staging): $ErrMessage\n";
    return 0;
  }
}


#
# Command line processing
#

my ($OptCreate, %OptTypes, $Usage);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--create")
  {
    $OptCreate = 1;
  }
  elsif ($TaskTypes{$Arg})
  {
    $OptTypes{$Arg} = 1;
  }
  elsif ($Arg eq "--debug")
  {
    $Debug = 1;
  }
  elsif ($Arg eq "--log-only")
  {
    $LogOnly = 1;
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
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check parameters
if (!defined $Usage)
{
  map { $OptTypes{$_} = 1 } keys %TaskTypes if (!%OptTypes);
}
if (defined $Usage)
{
  print "Usage: $Name0 [--debug] [--log-only] [--help] [--create] [TASKTYPE] ...\n";
  print "\n";
  print "Where TASKTYPE is one of: ", join(" ", sort keys %TaskTypes), "\n";
  exit $Usage;
}


#
# Create the 32 bit tasks
#

my $Rc = 0;
if ($OptTypes{build} or $OptTypes{base32} or $OptTypes{winetest32})
{
  my ($Create, $LatestBaseName) = UpdateWineTest($OptCreate, 32);
  if ($Create < 0)
  {
    $Rc = 1;
  }
  elsif ($Create == 1)
  {
    # A new executable means there have been commits so update Wine. Create
    # this job first purely to make the WineTestBot job queue look nice, and
    # arbitrarily do it only for 32-bit executables to avoid redundant updates.
    $Rc = 1 if ($OptTypes{build} and !AddReconfigJob());
    $Rc = 1 if ($OptTypes{base32} and !AddJob("base", $LatestBaseName, 32));
    $Rc = 1 if ($OptTypes{winetest32} and !AddJob("", $LatestBaseName, 32));
  }
}


#
# Create the 64 bit tasks
#

if ($OptTypes{all64})
{
  my ($Create, $LatestBaseName) = UpdateWineTest($OptCreate, 64);
  if ($Create < 0)
  {
    $Rc = 1;
  }
  elsif ($Create == 1)
  {
    $Rc = 1 if ($OptTypes{all64} and !AddJob("", $LatestBaseName, 64));
  }
}

RescheduleJobs();

LogMsg "Submitted jobs\n";

exit $Rc;

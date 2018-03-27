#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# This script performs janitorial tasks. It removes incomplete patch series,
# archives old jobs and purges older jobs and patches.
#
# Copyright 2009 Ge van Geldorp
# Copyright 2017 Francois Gouget
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

use File::Path;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::Log;
use WineTestBot::Patches;
use WineTestBot::PendingPatchSets;
use WineTestBot::CGI::Sessions;
use WineTestBot::RecordGroups;
use WineTestBot::Tasks;
use WineTestBot::Users;
use WineTestBot::VMs;

my $LogOnly;
sub Trace(@)
{
  print @_ if (!$LogOnly);
  LogMsg @_;
}

sub Error(@)
{
  print STDERR "$Name0:error: ", @_ if (!$LogOnly);
  LogMsg @_;
}



$ENV{PATH} = "/usr/bin:/bin";
delete $ENV{ENV};

# Grab the command line options
my ($Usage, $DryRun);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--dry-run")
  {
    $DryRun = 1;
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
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}
# Check parameters
if (defined $Usage)
{
  print "Usage: $Name0 [--dry-run] [--log-only] [--help]\n";
  exit $Usage;
}


#
# Main
#

# Delete obsolete Jobs
if ($JobPurgeDays != 0)
{
  my $Jobs = CreateJobs();
  $Jobs->AddFilter("Submitted", [time() - $JobPurgeDays * 86400], "<");
  foreach my $Job (@{$Jobs->GetItems()})
  {
    Trace "Deleting job ", $Job->Id, "\n";
    next if ($DryRun);

    $Job->RmTree();
    my $ErrMessage = $Jobs->DeleteItem($Job);
    Error "$ErrMessage\n" if (defined $ErrMessage);
  }
}

# Delete PatchSets that are more than a day old
my $DeleteBefore = time() - 1 * 86400;
my $Sets = CreatePendingPatchSets();
foreach my $Set (@{$Sets->GetItems()})
{
  my $MostRecentPatch;
  foreach my $Part (@{$Set->Parts->GetItems()})
  {
    my $Patch = $Part->Patch;
    if (! defined($MostRecentPatch) ||
        $MostRecentPatch->Received < $Patch->Received)
    {
      $MostRecentPatch = $Patch;
    }
  }
  if (! defined($MostRecentPatch) ||
      $MostRecentPatch->Received < $DeleteBefore)
  {
    Error "Deleting pending series for ", $Set->EMail, "\n";
    next if ($DryRun);

    $Sets->DeleteItem($Set);
    $MostRecentPatch->Disposition("Incomplete series, discarded");
    $MostRecentPatch->Save();
  }
}

# Delete obsolete Patches now that no Job references them
if ($JobPurgeDays != 0)
{
  my $Patches = CreatePatches();
  $Patches->AddFilter("Received", [time() - $JobPurgeDays * 86400], "<");
  foreach my $Patch (@{$Patches->GetItems()})
  {
    my $Jobs = CreateJobs();
    $Jobs->AddFilter("Patch", [$Patch]);
    if ($Jobs->IsEmpty())
    {
      Trace "Deleting patch ", $Patch->Id, "\n";
      next if ($DryRun);

      unlink("$DataDir/patches/" . $Patch->Id);
      my $ErrMessage = $Patches->DeleteItem($Patch);
      Error "$ErrMessage\n" if (defined $ErrMessage);
    }
  }
}

# Archive old Jobs, that is remove all their associated files
if ($JobArchiveDays != 0)
{
  my $ArchiveBefore = time() - $JobArchiveDays * 86400;
  my $Jobs = CreateJobs();
  $Jobs->FilterNotArchived();
  foreach my $Job (@{$Jobs->GetItems()})
  {
    if (defined($Job->Ended) && $Job->Ended < $ArchiveBefore)
    {
      Trace "Archiving job ", $Job->Id, "\n";
      next if ($DryRun);

      foreach my $Step (@{$Job->Steps->GetItems()})
      {
        unlink $Step->GetDir() . "/" . $Step->FileName;
      }

      $Job->Archived(1);
      $Job->Save();
    }
  }
}

# Purge the deleted VMs if they are not referenced anymore
my $VMs = CreateVMs();
$VMs->AddFilter("Role", ["deleted"]);
my %DeletedVMs;
map { $DeletedVMs{$_} = 1 } @{$VMs->GetKeys()};

if (%DeletedVMs)
{
  foreach my $Task (@{CreateTasks($VMs)->GetItems()})
  {
    if (exists $DeletedVMs{$Task->VM->Name})
    {
      Trace "Keeping the ", $Task->VM->Name, " VM for task ", join("/", @{$Task->GetMasterKey()}), "\n";
      delete $DeletedVMs{$Task->VM->Name};
      last if (!%DeletedVMs);
    }
  }
  foreach my $VMKey (keys %DeletedVMs)
  {
    Trace "Deleting the $VMKey VM\n";
    next if ($DryRun);

    my $VM = $VMs->GetItem($VMKey);
    my $ErrMessage = $VMs->DeleteItem($VM);
    if (defined $ErrMessage)
    {
      Error "Unable to delete the $VMKey VM: $ErrMessage\n";
    }
  }
}

# Purge the deleted users if they are not referenced anymore
my $Users = CreateUsers();
$Users->AddFilter("Status", ["deleted"]);
my %DeletedUsers;
map { $DeletedUsers{$_} = 1 } @{$Users->GetKeys()};

if (%DeletedUsers)
{
  foreach my $Job (@{CreateJobs($Users)->GetItems()})
  {
    if (exists $DeletedUsers{$Job->User->Name})
    {
      Trace "Keeping the ", $Job->User->Name, " account for job ", $Job->Id, "\n";
      delete $DeletedUsers{$Job->User->Name};
      last if (!%DeletedUsers);
    }
  }

  foreach my $UserKey (keys %DeletedUsers)
  {
    Trace "Deleting the $UserKey account\n";
    next if ($DryRun);

    my $User = $Users->GetItem($UserKey);
    DeleteSessions($User);
    my $ErrMessage = $Users->DeleteItem($User);
    if (defined $ErrMessage)
    {
      Error "Unable to delete the $UserKey account: $ErrMessage\n";
    }
  }
}

# Check the content of the staging directory
if (opendir(my $dh, "$DataDir/staging"))
{
  # We will be deleting files so read the directory in one go
  my @Entries = readdir($dh);
  close($dh);
  foreach my $Entry (@Entries)
  {
    next if ($Entry eq "." or $Entry eq "..");
    $Entry =~ m%^([^/]+)$%;
    my $FileName = "$DataDir/staging/$1";
    my $Age = int((-M $FileName) + 0.5);

    if ($Entry !~ /^[0-9a-f]{32}-websubmit_/)
    {
      if ($Entry !~ /^[0-9a-f]{32}_(?:patch|patch\.diff|wine-patches|winetest(?:64)?-latest\.exe|work)$/)
      {
        Trace "Found a suspicious staging file: $Entry\n";
      }

      if ($JobPurgeDays != 0)
      {
        if ($Age >= $JobPurgeDays + 7)
        {
          Trace "Deleting '$FileName'\n";
          if (!$DryRun and !rmtree($FileName))
          {
            Error "Could not delete '$FileName': $!\n";
          }
        }
        elsif ($Age > $JobPurgeDays)
        {
          Error "'$FileName' is $Age days old and should have been deleted already. It will be deleted in ", $JobPurgeDays + 7 - $Age, " day(s).\n";
        }
      }
    }
    elsif ($Age >= 1)
    {
      Trace "Deleting '$FileName'\n";
      if (!$DryRun and !unlink $FileName)
      {
        # The user abandoned the submit procedure half-way through
        Error "Could not delete '$FileName': $!\n";
      }
    }
  }
}
else
{
  Error "Unable to open '$DataDir/staging': $!";
}

# Delete obsolete record groups
if ($JobPurgeDays != 0)
{
  my $RecordGroups = CreateRecordGroups();
  $RecordGroups->AddFilter("Timestamp", [time() - $JobPurgeDays * 86400], "<");
  foreach my $RecordGroup (@{$RecordGroups->GetItems()})
  {
    if ($DryRun)
    {
      Trace "Deleting RecordGroup ", $RecordGroup->Id, "\n";
    }
    else
    {
      my $ErrMessage = $RecordGroups->DeleteItem($RecordGroup);
      Error "$ErrMessage\n" if (defined $ErrMessage);
    }
  }
}

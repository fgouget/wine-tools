#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# This script performs janitorial tasks. It removes incomplete patch series,
# archives old jobs and purges older jobs and patches.
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
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
}

use File::Path;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::Log;
use WineTestBot::Patches;
use WineTestBot::PendingPatchSets;
use WineTestBot::CGI::Sessions;
use WineTestBot::Users;
use WineTestBot::VMs;


$ENV{PATH} = "/usr/bin:/bin";
delete $ENV{ENV};

# Delete obsolete Jobs
if ($JobPurgeDays != 0)
{
  my $DeleteBefore = time() - $JobPurgeDays * 86400;
  my $Jobs = CreateJobs();
  foreach my $Job (@{$Jobs->GetItems()})
  {
    if (defined($Job->Ended) && $Job->Ended < $DeleteBefore)
    {
      LogMsg "Deleting job ", $Job->Id, "\n";
      $Job->RmTree();
      my $ErrMessage = $Jobs->DeleteItem($Job);
      if (defined($ErrMessage))
      {
        LogMsg $ErrMessage, "\n";
      }
    }
  }
  $Jobs = undef;
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
    LogMsg "Deleting pending series for ", $Set->EMail, "\n";
    $Sets->DeleteItem($Set);
    $MostRecentPatch->Disposition("Incomplete series, discarded");
    $MostRecentPatch->Save();
  }
}

# Delete obsolete Patches now that no Job references them
if ($JobPurgeDays != 0)
{
  $DeleteBefore = time() - $JobPurgeDays * 86400;
  my $Patches = CreatePatches();
  foreach my $Patch (@{$Patches->GetItems()})
  {
    if ($Patch->Received < $DeleteBefore)
    {
      my $Jobs = CreateJobs();
      $Jobs->AddFilter("Patch", [$Patch]);
      if ($Jobs->IsEmpty())
      {
        LogMsg "Deleting patch ", $Patch->Id, "\n";
        unlink("$DataDir/patches/" . $Patch->Id);
        my $ErrMessage = $Patches->DeleteItem($Patch);
        if (defined($ErrMessage))
        {
          LogMsg $ErrMessage, "\n";
        }
      }
    }
  }
  $Patches = undef;
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
      LogMsg "Archiving job ", $Job->Id, "\n";
      foreach my $Step (@{$Job->Steps->GetItems()})
      {
        unlink $Step->GetDir() . "/" . $Step->FileName;
      }

      $Job->Archived(1);
      $Job->Save();
    }
  }
  $Jobs = undef;
}

# Purge the deleted users and VMs if they are not referenced anymore
my $VMs = CreateVMs();
$VMs->AddFilter("Role", ["deleted"]);
my %DeletedVMs;
map { $DeletedVMs{$_} = 1 } @{$VMs->GetKeys()};

my $Users = CreateUsers();
$Users->AddFilter("Status", ["deleted"]);
my %DeletedUsers;
map { $DeletedUsers{$_} = 1 } @{$Users->GetKeys()};

if (%DeletedUsers or %DeletedVMs)
{
  foreach my $Job (@{CreateJobs()->GetItems()})
  {
    if (exists $DeletedUsers{$Job->User->Name})
    {
      LogMsg "Keeping the ", $Job->User->Name, " account for job ", $Job->Id, "\n";
      delete $DeletedUsers{$Job->User->Name};
    }

    if (%DeletedVMs)
    {
      foreach my $Step (@{$Job->Steps->GetItems()})
      {
        foreach my $Task (@{$Step->Tasks->GetItems()})
        {
          if (exists $DeletedVMs{$Task->VM->Name})
          {
            LogMsg "Keeping the ", $Task->VM->Name, " VM for task ", join("/", @{$Task->GetMasterKey()}), "\n";
            delete $DeletedVMs{$Task->VM->Name};
          }
        }
      }
    }
  }

  if (%DeletedUsers)
  {
    foreach my $UserName (keys %DeletedUsers)
    {
      my $User = $Users->GetItem($UserName);
      DeleteSessions($User);
      my $ErrMessage = $Users->DeleteItem($User);
      if (defined $ErrMessage)
      {
        LogMsg "Unable to delete the $UserName account: $ErrMessage\n";
      }
      else
      {
        LogMsg "Deleted the $UserName account\n";
      }
    }
  }

  foreach my $VMKey (keys %DeletedVMs)
  {
    my $VM = $VMs->GetItem($VMKey);
    my $ErrMessage = $VMs->DeleteItem($VM);
    if (defined $ErrMessage)
    {
      LogMsg "Unable to delete the $VMKey VM: $ErrMessage\n";
    }
    else
    {
      LogMsg "Deleted the $VMKey VM\n";
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

    if ($Entry =~ /^[0-9a-f]{32}-websubmit_/)
    {
      if ($Age >= 1 and !unlink $FileName)
      {
        # The user abandoned the submit procedure half-way through
        LogMsg "Could not delete '$FileName': $!\n" if (!unlink($FileName));
      }
    }
    else
    {
      if ($Entry !~ /^[0-9a-f]{32}_(?:patch|patch\.diff|wine-patches|winetest(?:64)?-latest\.exe|work)$/)
      {
        LogMsg "Found a suspicious staging file: $Entry\n";
      }

      if ($JobPurgeDays != 0)
      {
        if ($Age >= $JobPurgeDays + 7)
        {
          if ((-d $FileName and !rmtree($FileName)) or
              !unlink($FileName))
          {
            LogMsg "Could not delete '$FileName': $!\n";
          }
        }
        elsif ($Age > $JobPurgeDays)
        {
          LogMsg "'$FileName' is $Age days old and should have been deleted already. It will be deleted in ", $JobPurgeDays + 7 - $Age, " day(s).\n";
        }
      }
    }
  }
}
else
{
  LogMsg "0Unable to open '$DataDir/staging': $!";
}

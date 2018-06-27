# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2010 Ge van Geldorp
# Copyright 2012 Francois Gouget
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

package WineTestBot::Patch;

=head1 NAME

WineTestBot::Patch - A patch to be tested

=head1 DESCRIPTION

A WineTestBot::Patch object tracks a patch submitted by a user or collected
from the mailing list. If it is part of a patch series, then a
WineTestBot::PendingPatchSet object will be created to track the series and
linked to this patch through a WineTestBot::PendingPatch object.

=cut

use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotItem);

use Encode qw/decode/;
use File::Basename;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::PatchUtils;
use WineTestBot::Users;
use WineTestBot::Utils;
use WineTestBot::VMs;
use WineTestBot::Engine::Notify;


sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->Received(time());

  $self->SUPER::InitializeNew($Collection);
}

=pod
=over 12

=item C<FromSubmission()>

Initializes a WineTestBot::Patch object from the given message.

=back
=cut

sub FromSubmission($$)
{
  my ($self, $MsgEntity) = @_;

  my $Head = $MsgEntity->head;
  my @From = Mail::Address->parse($Head->get("From"));
  if (defined($From[0]))
  {
    my $FromName = $From[0]->name;
    if (! $FromName && substr($From[0]->phrase, 0, 2) eq "=?")
    {
      $FromName = decode('MIME-Header', $From[0]->phrase);
    }
    if (! $FromName)
    {
      $FromName = $From[0]->user;
    }
    my $PropertyDescriptor = $self->GetPropertyDescriptorByName("FromName");
    $self->FromName(substr($FromName, 0, $PropertyDescriptor->GetMaxLength()));
    my $FromEMail = $From[0]->address;
    $PropertyDescriptor = $self->GetPropertyDescriptorByName("FromEMail");
    if (length($FromEMail) <= $PropertyDescriptor->GetMaxLength())
    {
      $self->FromEMail($FromEMail);
    }
  }
  my $Subject = $Head->get("Subject");
  $Subject =~ s/\s*\n\s*/ /gs;
  my $PropertyDescriptor = $self->GetPropertyDescriptorByName("Subject");
  $self->Subject(substr($Subject, 0, $PropertyDescriptor->GetMaxLength()));

  my $MessageId = $Head->get("Message-Id");
  if ($MessageId)
  {
    $MessageId =~ s/\s*\n\s*/ /gs;
    $PropertyDescriptor = $self->GetPropertyDescriptorByName("MessageId");
    $self->MessageId(substr($MessageId, 0, $PropertyDescriptor->GetMaxLength()));
  }

  $self->Disposition("Processing");
}


=pod
=over 12

=item C<Submit()>

Analyzes the current patch to determine which Wine tests are impacted. Then for
each impacted test it creates a high priority WineTestBot::Job to run that test.
This also creates the WineTestBot::Step objects for that Job, as well as the
WineTestBot::Task objects to run the test on each 'base' VM. It is the
responsibility of the caller to arrange for rescheduling of the jobs.

Note that the path to the file containing the actual patch is passed as a
parameter. This is used to apply a combined patch for patch series. See
WineTestBot::PendingPatchSet::SubmitSubset().

=back
=cut

sub Submit($$$)
{
  my ($self, $PatchFileName, $IsSet) = @_;

  my $PastImpacts;
  $PastImpacts = GetPatchImpact($PatchFileName) if ($IsSet);
  my $Impacts = GetPatchImpact("$DataDir/patches/" . $self->Id, undef, $PastImpacts);

  if (!$Impacts->{WineBuild} and !$Impacts->{ModuleBuild} and
      !$Impacts->{TestBuild})
  {
    if ($Impacts->{IsWinePatch})
    {
      $self->Disposition(($IsSet ? "Part does" : "Does")
                         ." not impact the Wine build");
    }
    else
    {
      $self->Disposition(($IsSet ? "Part is not" : "Not") ." a Wine patch");
    }
    return undef;
  }

  # Create a new job for this patch
  my $Jobs = CreateJobs();
  my $NewJob = $Jobs->Add();
  $NewJob->Priority(6);
  my $PropertyDescriptor = $Jobs->GetPropertyDescriptorByName("Remarks");
  my $Subject = $self->Subject;
  $Subject =~ s/\[PATCH[^\]]*]//i;
  $Subject =~ s/[[\(]?\d+\/\d+[\)\]]?//;
  $Subject =~ s/^\s*//;
  $NewJob->Remarks(substr("[wine-patches] " . $Subject, 0,
                          $PropertyDescriptor->GetMaxLength()));
  $NewJob->Patch($self);

  my $User;
  my $Users = CreateUsers();
  if (defined $self->FromEMail)
  {
    $Users->AddFilter("EMail", [$self->FromEMail]);
    $User = @{$Users->GetItems()}[0] if (!$Users->IsEmpty());
  }
  $NewJob->User($User || GetBatchUser());

  my $BuildVMs = CreateVMs();
  $BuildVMs->AddFilter("Type", ["build"]);
  $BuildVMs->AddFilter("Role", ["base"]);
  if ($Impacts->{UnitCount} and !$BuildVMs->IsEmpty())
  {
    # Create the Build Step
    my $BuildStep = $NewJob->Steps->Add();
    $BuildStep->FileName("patch.diff");
    $BuildStep->FileType("patchdlls");
    $BuildStep->InStaging(!1);
    $BuildStep->Type("build");
    $BuildStep->DebugLevel(0);

    # Add build task
    my $BuildVM = ${$BuildVMs->GetItems()}[0];
    my $Task = $BuildStep->Tasks->Add();
    $Task->VM($BuildVM);
    $Task->Timeout($BuildTimeout);

    # Save the build step so the others can reference it.
    my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
    if (defined($ErrMessage))
    {
      $self->Disposition("Failed to submit build step");
      return $ErrMessage;
    }

    # Create steps for the Windows tests
    foreach my $Module (sort keys %{$Impacts->{Tests}})
    {
      my $TestInfo = $Impacts->{Tests}->{$Module};
      foreach my $Unit (sort keys %{$TestInfo->{Units}})
      {
        foreach my $Bits ("32", "64")
        {
          my $WinVMs = CreateVMs();
          $WinVMs->AddFilter("Type", $Bits eq "32" ? ["win32", "win64"] : ["win64"]);
          $WinVMs->AddFilter("Role", ["base"]);
          if (!$WinVMs->IsEmpty())
          {
            # Create one Step per (module, unit, bitness) combination
            my $NewStep = $NewJob->Steps->Add();
            $NewStep->PreviousNo($BuildStep->No);
            my $FileName = $TestInfo->{ExeBase};
            $FileName .= "64" if ($Bits eq "64");
            $NewStep->FileName("$FileName.exe");
            $NewStep->FileType("exe$Bits");
            $NewStep->InStaging(!1);

            # And a task for each VM
            my $Tasks = $NewStep->Tasks;
            my $SortedKeys = $WinVMs->SortKeysBySortOrder($WinVMs->GetKeys());
            foreach my $VMKey (@$SortedKeys)
            {
              my $VM = $WinVMs->GetItem($VMKey);
              my $Task = $Tasks->Add();
              $Task->VM($VM);
              $Task->Timeout($SingleTimeout);
              $Task->CmdLineArg($Unit);
            }
          }
        }
      }
    }
  }

  my $WineVMs = CreateVMs();
  $WineVMs->AddFilter("Type", ["wine"]);
  $WineVMs->AddFilter("Role", ["base"]);
  if (!$WineVMs->IsEmpty())
  {
    # Add a Wine step to the job
    my $NewStep = $NewJob->Steps->Add();
    $NewStep->FileName("patch.diff");
    $NewStep->FileType("patchdlls");
    $NewStep->InStaging(!1);
    $NewStep->DebugLevel(0);

    # And a task for each VM
    my $Tasks = $NewStep->Tasks;
    my $SortedKeys = $WineVMs->SortKeysBySortOrder($WineVMs->GetKeys());
    foreach my $VMKey (@$SortedKeys)
    {
      my $VM = $WineVMs->GetItem($VMKey);
      my $Task = $Tasks->Add();
      $Task->VM($VM);
      # Only verify that the win32 version compiles
      $Task->Timeout($WineReconfigTimeout);
      $Task->CmdLineArg("win32");
    }
  }

  if ($NewJob->Steps->IsEmpty())
  {
    # This may be a Wine patch but there is no suitable VM to test it!
    if ($Impacts->{UnitCount})
    {
      $self->Disposition("No build or test VM!");
    }
    else
    {
      $self->Disposition(($IsSet ? "Part does" : "Does") ." not impact the ".
                         ($WineVMs->IsEmpty() ? "Windows " : "") ."tests");
    }
    return undef;
  }

  # Save it all
  my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    $self->Disposition("Failed to submit job");
    return $ErrMessage;
  }

  # Stage the patch so it can be picked up by the job
  if (!link($PatchFileName, "$DataDir/staging/job". $NewJob->Id ."_patch.diff"))
  {
    $self->Disposition("Failed to stage the patch file");
    return $!;
  }

  # Switch Status to staging to indicate we are done setting up the job
  $NewJob->Status("staging");
  ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    $self->Disposition("Failed to submit job (staging)");
    return $ErrMessage;
  }

  $self->Disposition("Submitted job ". $NewJob->Id);
  return undef;
}

sub GetEMailRecipient($)
{
  my ($self) = @_;

  return BuildEMailRecipient($self->FromEMail, $self->FromName);
}


package WineTestBot::Patches;

=head1 NAME

WineTestBot::Patches - A collection of WineTestBot::Patch objects

=cut

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
BEGIN
{
  our @ISA = qw(WineTestBot::WineTestBotCollection);
  our @EXPORT = qw(CreatePatches);
}

use ObjectModel::BasicPropertyDescriptor;
use WineTestBot::Config;
use WineTestBot::PendingPatchSets;


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Patch->new($self);
}

my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("Id", "Patch id", 1, 1, "S",  7),
  CreateBasicPropertyDescriptor("WebPatchId", "Wine Web Patch id", !1, !1, "N",  7),
  CreateBasicPropertyDescriptor("Received", "Received", !1, 1, "DT", 19),
  CreateBasicPropertyDescriptor("AffectsTests", "Affects tests", !1, 1, "B", 1),
  CreateBasicPropertyDescriptor("FromName", "Author", !1, !1, "A", 40),
  CreateBasicPropertyDescriptor("FromEMail", "Author's email address", !1, !1, "A", 40),
  CreateBasicPropertyDescriptor("Subject", "Subject", !1, !1, "A", 120),
  CreateBasicPropertyDescriptor("MessageId", "Message id", !1, !1, "A", 256),
  CreateBasicPropertyDescriptor("Disposition", "Disposition", !1, 1, "A", 40),
);

=pod
=over 12

=item C<CreatePatches()>

Creates a collection of Patch objects.

=back
=cut

sub CreatePatches(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::Patches->new("Patches", "Patches", "Patch",
                                   \@PropertyDescriptors, $ScopeObject);
}

sub IsPatch($$)
{
  my ($self, $Body) = @_;

  if (open(BODY, "<" . $Body->path))
  {
    my $Line;
    while (defined($Line = <BODY>))
    {
      if ($Line =~ m/^\+\+\+ /)
      {
        close BODY;
        return 1;
      }
    }
    close BODY;
  }

  return !1;
}

=pod
=over 12

=item C<NewPatch()>

Creates a WineTestBot::Patch object for the given message. If the message
does impact Wine's tests then the Patch object disposition is set and no
further action is performed. Otherwise if the patch is part of a series then
it gets tied to a WineTestBot::PendingPatchSet object by
WineTestBot::PendingPatchSets::NewSubmission(). If the patch is independent of
others, then C<WineTestBot::Patch::Submit()> is called right away.

=back
=cut

sub NewPatch($$$)
{
  my ($self, $MsgEntity, $WebPatchId) = @_;

  my $Patch = $self->Add();
  $Patch->WebPatchId($WebPatchId) if (defined $WebPatchId);
  $Patch->FromSubmission($MsgEntity);

  my @PatchBodies;
  foreach my $Part ($MsgEntity->parts_DFS)
  {
    if (defined($Part->bodyhandle))
    {
      if ($Part->effective_type ne "text/html" &&
          $self->IsPatch($Part->bodyhandle))
      {
        $PatchBodies[scalar(@PatchBodies)] = $Part->bodyhandle;
      }
      else
      {
        $Part->bodyhandle->purge();
      }
    }
  }

  my $ErrMessage;
  if (scalar(@PatchBodies) == 1)
  {
    my $Subject = $Patch->Subject;
    $Subject =~ s/32\/64//;
    $Subject =~ s/64\/32//;
    if ($Subject =~ m/\d+\/\d+/)
    {
      $Patch->Disposition("Checking series");
      my $ErrKey;
      my $ErrProperty;
      ($ErrKey, $ErrProperty, $ErrMessage) = $self->Save();
      link($PatchBodies[0]->path, "$DataDir/patches/" . $Patch->Id);
      if (! defined($ErrMessage))
      {
        $ErrMessage = CreatePendingPatchSets()->NewSubmission($Patch);
      }
    }
    else
    {
      $Patch->Disposition("Checking patch");
      my $ErrKey;
      my $ErrProperty;
      ($ErrKey, $ErrProperty, $ErrMessage) = $self->Save();
      link($PatchBodies[0]->path, "$DataDir/patches/" . $Patch->Id);
      if (! defined($ErrMessage))
      {
        $ErrMessage = $Patch->Submit($PatchBodies[0]->path, !1);
      }
    }
  }
  elsif (scalar(@PatchBodies) == 0)
  {
    $Patch->Disposition("No patch found");
  }
  else
  {
    $Patch->Disposition("Message contains multiple patches");
  }

  foreach my $PatchBody (@PatchBodies)
  {
    $PatchBody->purge();
  }
  
  if (! defined($ErrMessage))
  {
    my ($ErrKey, $ErrProperty, $ErrMessage) = $self->Save();
    if (defined($ErrMessage))
    {
      return $ErrMessage;
    }
  }

  return undef;
}

1;

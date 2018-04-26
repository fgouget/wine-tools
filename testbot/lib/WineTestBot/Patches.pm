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
use WineTestBot::PendingPatchSets;
use WineTestBot::Jobs;
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

=item C<GetTestList()>

Returns a hashtable containing the list of the source files for a given module.
This structure is built from the latest/testlist.txt file.

=back
=cut

sub GetTestList()
{
  my $TestList = {};
  if (open(my $File, "<", "$DataDir/latest/testlist.txt"))
  {
    while (my $TestFileName = <$File>)
    {
      chomp $TestFileName;
      if ($TestFileName =~ m~^(?:dlls|programs)/([^/]+)/tests/[^/]+\.c$~)
      {
        my $Module = $1;
        push @{$TestList->{$Module}}, $TestFileName;
      }
    }
    close($File);
  }
  return $TestList;
}

=pod
=over 12

=item C<Submit()>

Analyzes the current patch to determine which Wine tests are impacted. Then for
each impacted test it creates a high priority WineTestBot::Job to run that test.
This also creates the WineTestBot::Step objects for that Job, as well as the
WineTestBot::Task objects to run the test on each 'base' VM. Finally it calls
C<WineTestBot::Jobs::ScheduleJobs()> to run the new Jobs.

Note that the path to the file containing the actual patch is passed as a
parameter. This is used to apply a combined patch for patch series. See
WineTestBot::PendingPatchSet::SubmitSubset().

=back
=cut

sub Submit($$$)
{
  my ($self, $PatchFileName, $IsSet) = @_;

  # See also OnSubmit() in web/Submit.pl
  my (%Modules, %Deleted);
  if (open(BODY, "<$DataDir/patches/" . $self->Id))
  {
    my ($Line, $Modified);
    while (defined($Line = <BODY>))
    {
      if ($Line =~ m~^\-\-\- .*/((?:dlls|programs)/[^/]+/tests/[^/\s]+)~)
      {
        $Modified = $1;
      }
      elsif ($Line =~ m~^\+\+\+ .*/(dlls|programs)/([^/]+)/tests/([^/\s]+)~)
      {
        my ($FileType, $Module, $Unit) = ("patch$1", $2, $3);
        # Assume makefile modifications may break the build but not the tests
        next if ($Unit eq "Makefile.in");
        $Unit = "" if ($Unit !~ s/\.c$//);
        $Modules{$Module}{$Unit} = $FileType;
      }
      elsif ($Line =~ m~^\+\+\+ /dev/null~ and defined $Modified)
      {
        $Deleted{$Modified} = 1;
      }
      else
      {
        $Modified = undef;
      }
    }
    close BODY;
  }

  if (! scalar(%Modules))
  {
    $self->Disposition(($IsSet ? "Set" : "Patch") .
                       " doesn't affect tests");
    return undef;
  }

  my $User;
  my $Users = CreateUsers();
  if (defined($self->FromEMail))
  {
    $Users->AddFilter("EMail", [$self->FromEMail]);
    if (! $Users->IsEmpty())
    {
      $User = @{$Users->GetItems()}[0];
    }
  }
  if (! defined($User))
  {
    $User = GetBatchUser();
  }

  my $TestList;
  foreach my $Module (keys %Modules)
  {
    next if (!defined $Modules{$Module}{""});

    # The patch modifies non-C files so rerun all that module's test units
    $TestList = GetTestList() if (!$TestList);
    next if (!defined $TestList->{$Module});

    # If we don't find which tests to rerun then run the module test
    # executable without argument. It probably won't work but will make the
    # issue clearer to the developer.
    my $FileType = $Modules{$Module}{""};
    foreach my $TestFileName (@{$TestList->{$Module}})
    {
      if (!$Deleted{$TestFileName} and
          $TestFileName =~ m~^(?:dlls|programs)/\Q$Module\E/tests/([^/]+)\.c$~)
      {
        my $Unit = $1;
        $Modules{$Module}{$Unit} = $FileType;
        delete $Modules{$Module}{""};
      }
    }
  }

  my $Disposition = "Submitted job ";
  my $First = 1;
  foreach my $Module (keys %Modules)
  {
    my $Jobs = WineTestBot::Jobs::CreateJobs();

    # Create a new job for this patch
    my $NewJob = $Jobs->Add();
    $NewJob->User($User);
    $NewJob->Priority(6);
    my $PropertyDescriptor = $Jobs->GetPropertyDescriptorByName("Remarks");
    my $Subject = $self->Subject;
    $Subject =~ s/\[PATCH[^\]]*]//i;
    $Subject =~ s/[[\(]?\d+\/\d+[\)\]]?//;
    $Subject =~ s/^\s*//;
    $NewJob->Remarks(substr("[wine-patches] " . $Subject, 0,
                            $PropertyDescriptor->GetMaxLength()));
    $NewJob->Patch($self);
  
    # Add build step to the job
    my $Steps = $NewJob->Steps;
    my $NewStep = $Steps->Add();
    # Create a link to the patch file in the staging dir
    my $StagingFileName = CreateNewLink($PatchFileName, "$DataDir/staging", "_patch.diff");
    $NewStep->FileName(basename($StagingFileName));
    my @Keys = keys %{$Modules{$Module}};
    $NewStep->FileType($Modules{$Module}{$Keys[0]});
    $NewStep->InStaging(1);
    $NewStep->Type("build");
    $NewStep->DebugLevel(0);
  
    # Add build task
    my $VMs = CreateVMs();
    $VMs->AddFilter("Type", ["build"]);
    $VMs->AddFilter("Role", ["base"]);
    my $BuildVM = ${$VMs->GetItems()}[0];
    my $Task = $NewStep->Tasks->Add();
    $Task->VM($BuildVM);
    $Task->Timeout($BuildTimeout);

    # Save this step (&job+task) so the others can reference it
    my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
    if (defined($ErrMessage))
    {
      $self->Disposition("Failed to submit build step");
      return $ErrMessage;
    }

    foreach my $Unit (keys %{$Modules{$Module}})
    {
      # Add 32 and 64-bit tasks
      foreach my $Bits ("32", "64")
      {
        $VMs = CreateVMs();
        $VMs->AddFilter("Type", $Bits eq "32" ? ["win32", "win64"] : ["win64"]);
        $VMs->AddFilter("Role", ["base"]);
        if (@{$VMs->GetKeys()})
        {
          # Create the corresponding Step
          $NewStep = $Steps->Add();
          $NewStep->PreviousNo(1);
          my $FileName = $Module;
          $FileName .= ".exe" if ($Modules{$Module}{$Unit} eq "patchprograms");
          $FileName .= "_test";
          $FileName .= "64" if ($Bits eq "64");
          $NewStep->FileName("$FileName.exe");
          $NewStep->FileType("exe$Bits");
          $NewStep->InStaging(!1);

          # And a task for each VM
          my $Tasks = $NewStep->Tasks;
          my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
          foreach my $VMKey (@$SortedKeys)
          {
            my $VM = $VMs->GetItem($VMKey);
            my $Task = $Tasks->Add();
            $Task->VM($VM);
            $Task->Timeout($SingleTimeout);
            $Task->CmdLineArg($Unit);
          }
        }
      }
    }

    ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
    if (defined($ErrMessage))
    {
      $self->Disposition("Failed to submit job");
      return $ErrMessage;
    }

    if ($First)
    {
      $First = !1;
    }
    else
    {
      $Disposition .= ", ";
    }
    $Disposition .= $NewJob->Id;
  }
  $self->Disposition($Disposition);

  WineTestBot::Jobs::ScheduleJobs();

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

sub IsTestPatch($$)
{
  my ($self, $Body) = @_;

  if (open(BODY, "<" . $Body->path))
  {
    my $Line;
    while (defined($Line = <BODY>))
    {
      if ($Line =~ m/^\+\+\+ .*\/(dlls|programs)\/[^\/]+\/tests\/[^\/\s]+/)
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
    $Patch->AffectsTests($self->IsTestPatch($PatchBodies[0]));
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
        $ErrMessage = WineTestBot::PendingPatchSets::CreatePendingPatchSets()->NewSubmission($Patch);
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

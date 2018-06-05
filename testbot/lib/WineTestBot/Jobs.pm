# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2017 Francois Gouget
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


package WineTestBot::Job;

=head1 NAME

WineTestBot::Job - A job submitted by a user

=head1 DESCRIPTION

A Job is created when a WineTestBot::User asks for something to be tested
(for automatically generated Jobs this would be the batch user). A Job is
composed of one or more WineTestBot::Step objects. There are many
paths that can result in the creation of a job:

=over

=item *
A user submits a patch or binary to test.

=item *
WineTestBot finds a patch to test on the mailing list (and has all the pieces
it needs for that patch, see WineTestBot::PendingPatchSet).

=item *
WineTestBot notices a Wine commit round and decides to run the full suite of
tests. In this case there is no WineTestBot::Patch object associated with the
Job.

=back

A Job's lifecycle is as follows:
=over

=item *
A Job is created with Status set to queued which means it is ready to run.

=item *
As soon as one of the Step starts running, the Job's Status field is set to
running.

=item *
Once all the Steps have completed the Job's Status is updated to reflect the
overall result: completed, badpatch, etc.

=item *
If the Job is canceled by the user, then the Status field is set to canceled.

=back

=cut

use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotItem);

use File::Path;

use WineTestBot::Config;
use WineTestBot::Branches;
use WineTestBot::Engine::Notify;


sub _initialize($$)
{
  my ($self, $Collection) = @_;

  $self->SUPER::_initialize($Collection);

  $self->{OldStatus} = undef;
}

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->Branch(CreateBranches()->GetDefaultBranch());
  $self->Status("queued");
  $self->Submitted(time());

  $self->SUPER::InitializeNew($Collection);
}

=pod
=over 12

=item C<OnDelete()>

Resets the Steps PreviousNo fields because the corresponding foreign key
references both this Job and the Steps, thus preventing their deletion.

=back
=cut

sub OnDelete($)
{
  my ($self) = @_;

  my $Steps = $self->Steps;
  map { $_->PreviousNo(undef) } @{$Steps->GetItems()};
  my ($_ErrKey, $_ErrProperty, $ErrMessage) = $Steps->Save();

  return $ErrMessage || $self->SUPER::OnDelete();
}

sub GetDir($)
{
  my ($self) = @_;
  my $JobId = $self->GetKey();
  return "$DataDir/jobs/$JobId";
}

sub CreateDir($)
{
  my ($self) = @_;
  my $Dir = $self->GetDir();
  mkpath($Dir, 0, 0775);
  return $Dir;
}

sub RmTree($)
{
  my ($self) = @_;
  my $Dir = $self->GetDir();
  rmtree($Dir);
}

sub Status($;$)
{
  my ($self, $NewStatus) = @_;

  my $CurrentStatus = $self->SUPER::Status;
  return $CurrentStatus if (!defined $NewStatus);

  if (! defined($CurrentStatus) || $NewStatus ne $CurrentStatus)
  {
    $self->SUPER::Status($NewStatus);
    $self->{OldStatus} = $CurrentStatus;
  }

  return $NewStatus;
}

sub OnSaved($)
{
  my ($self) = @_;

  $self->SUPER::OnSaved();

  if (defined($self->{OldStatus}))
  {
    my $NewStatus = $self->Status;
    if ($NewStatus ne $self->{OldStatus})
    {
      JobStatusChange($self->GetKey(), $self->{OldStatus}, $NewStatus);
    }
  }
}

=pod
=over 12

=item C<UpdateStatus()>

Updates the status of this job and of its steps and tasks. Part of this means
checking for failed builds and skipping the subsequent tasks, or detecting
dead child processes.

Returns the updated status.

=back
=cut

sub UpdateStatus($)
{
  my ($self) = @_;

  my $Status = $self->Status;
  return $Status if ($Status ne "queued" && $Status ne "running");

  my %Has;
  my $Steps = $self->Steps;
  my @SortedSteps = sort { $a->No <=> $b->No } @{$Steps->GetItems()};
  foreach my $Step (@SortedSteps)
  {
    my $Skip;
    if ($Step->PreviousNo)
    {
      my $PrevStatus = $Steps->GetItem($Step->PreviousNo)->Status;
      if ($PrevStatus ne "queued" && $PrevStatus ne "running" &&
          $PrevStatus ne "completed")
      {
        # The previous step was supposed to provide binaries but it failed
        # or was canceled. So skip this one.
        $Skip = 1;
      }
    }

    my $StepStatus = $Step->UpdateStatus($Skip);
    $Has{$StepStatus} = 1;
  }

  # Inherit the steps most significant status.
  # Note that one or more tasks may have been requeued during the cleanup phase
  # of the server startup. So this job may regress from 'running' back to
  # 'queued'. This means all possible step status values must be considered.
  foreach my $StepStatus ("running", "boterror", "badpatch", "badbuild", "canceled", "skipped", "completed", "queued")
  {
    if ($Has{$StepStatus})
    {
      if ($Has{"queued"})
      {
        # Either nothing ran so this job is still / again 'queued', or not
        # everything has been run yet which means it's still 'running'.
        $Status = $StepStatus eq "queued" ? "queued" : "running";
      }
      else
      {
        # If all steps are skipped it's because the user canceled the job
        # before any of them could run.
        $Status = $StepStatus eq "skipped" ? "canceled" : $StepStatus;
      }
      $self->Status($Status);
      if ($Status ne "running" && $Status ne "queued" && !defined $self->Ended)
      {
        $self->Ended(time);
      }
      my ($ErrProperty, $ErrMessage) = $self->Save();
      if (defined $ErrMessage)
      {
        require WineTestBot::Log;
        WineTestBot::Log::LogMsg("Could not update job status: $ErrMessage\n");
      }
      last;
    }
  }

  return $Status;
}

=pod
=over 12

=item C<Cancel()>

Cancels the Job, preserving existing results.

More precisely, goes through all of that Job's 'queued' and 'running' tasks,
killing all the running ones and marking them, and all the queued tasks, as
'skipped' so they will not be run. The overall Job status will be 'canceled'
unless it was completed already.

Returns undef if successful, the error message otherwise.

=back
=cut

sub Cancel($)
{
  my ($self) = @_;
  my $ErrMessage;

  my $Steps = $self->Steps;
  $Steps->AddFilter("Status", ["queued", "running"]);
  foreach my $Step (@{$Steps->GetItems()})
  {
    my $Tasks = $Step->Tasks;
    $Tasks->AddFilter("Status", ["queued", "running"]);
    foreach my $Task (@{$Tasks->GetItems()})
    {
      my $VM = $Task->VM;
      if ($Task->Status eq "queued")
      {
        $Task->Status("skipped");
        my ($EProperty, $EMessage) = $Task->Save();
        $ErrMessage ||= "$EMessage ($EProperty)" if ($EMessage);
      }
      elsif (defined $VM->ChildPid)
      {
        require WineTestBot::Log;
        WineTestBot::Log::LogMsg("Canceling the " . join("/", $self->Id, $Step->No, $Task->No) . " task\n");
        $Task->Status("canceled");
        my ($EProperty, $EMessage) = $Task->Save();
        $ErrMessage ||= "$EMessage ($EProperty)" if ($EMessage);

        $VM->Status('dirty');
        $VM->KillChild();
        ($EProperty, $EMessage) = $VM->Save();
        $ErrMessage ||= "$EMessage ($EProperty)" if ($EMessage);
        $VM->RecordResult(undef, "canceled");
      }
    }
  }
  # Let UpdateStatus() handle updating the overall job status
  $self->UpdateStatus();

  return $ErrMessage;
}

=pod
=over 12

=item C<Restart()>

Restarts the Job from scratch.

More precisely, if the Job is not 'queued' or 'running', goes through all of
its tasks and marks them all as 'queued', deleting any existing result in the
process.

Returns undef if successful, the error message otherwise.

=back
=cut

sub Restart($)
{
  my ($self) = @_;

  if ($self->Status eq "queued" || $self->Status eq "running")
  {
    return "This job is already " . $self->Status;
  }

  my $FirstStep = 1;
  my $Steps = $self->Steps;
  my @SortedSteps = sort { $a->No <=> $b->No } @{$Steps->GetItems()};
  foreach my $Step (@SortedSteps)
  {
    my $Tasks = $Step->Tasks;
    foreach my $Task (@{$Tasks->GetItems()})
    {
      if ($FirstStep)
      {
        # The first step contains the patch or test executable
        # so only delete its task folders
        $Task->RmTree();
      }
      $Task->Status("queued");
      $Task->Started(undef);
      $Task->Ended(undef);
      $Task->TestFailures(undef);
    }
    # Subsequent steps only contain files generated by the previous steps
    $Step->RmTree() if (!$FirstStep);
    $FirstStep = undef;
    $Step->Status("queued");
  }
  $self->Status("queued");
  $self->Submitted(time);
  $self->Ended(undef);
  my ($ErrProperty, $ErrMessage) = $self->Save(); # Save it all
  return "$ErrMessage ($ErrProperty)" if ($ErrMessage);

  return undef;
}

sub GetEMailRecipient($)
{
  my ($self) = @_;

  if (defined($self->Patch) && defined($self->Patch->FromEMail))
  {
    return $self->Patch->FromEMail;
  }

  if ($self->User->EMail eq "/dev/null")
  {
    return undef;
  }

  return $self->User->GetEMailRecipient();
}

sub GetDescription($)
{
  my ($self) = @_;

  if (defined($self->Patch) && defined($self->Patch->FromEMail))
  {
    return $self->Patch->Subject;
  }

  return $self->Remarks;
}


package WineTestBot::Jobs;

=head1 NAME

WineTestBot::Jobs - A Job collection

=head1 DESCRIPTION

This collection contains all known jobs: those have have been run as well as
those that are yet to be run.

=cut

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
BEGIN
{
  our @ISA = qw(WineTestBot::WineTestBotCollection);
  our @EXPORT = qw(CreateJobs);
}

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::DetailrefPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::Branches;
use WineTestBot::Patches;
use WineTestBot::Steps;
use WineTestBot::Users;


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Job->new($self);
}

my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("Id", "Job id", 1, 1, "S",  5),
  CreateItemrefPropertyDescriptor("Branch", "Branch", !1, 1, \&CreateBranches, ["BranchName"]),
  CreateItemrefPropertyDescriptor("User", "Author", !1, 1, \&CreateUsers, ["UserName"]),
  CreateBasicPropertyDescriptor("Priority", "Priority", !1, 1, "N", 1),
  CreateEnumPropertyDescriptor("Status", "Status", !1, 1, ['queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled']),
  CreateBasicPropertyDescriptor("Remarks", "Remarks", !1, !1, "A", 128),
  CreateBasicPropertyDescriptor("Submitted", "Submitted", !1, !1, "DT", 19),
  CreateBasicPropertyDescriptor("Ended", "Ended", !1, !1, "DT", 19),
  CreateItemrefPropertyDescriptor("Patch", "Submitted from patch", !1, !1, \&CreatePatches, ["PatchId"]),
  CreateDetailrefPropertyDescriptor("Steps", "Steps", !1, !1, \&CreateSteps),
);
SetDetailrefKeyPrefix("Job", @PropertyDescriptors);

=pod
=over 12

=item C<CreateJobs()>

Creates a collection of Job objects.

=back
=cut

sub CreateJobs(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::Jobs->new("Jobs", "Jobs", "Job", \@PropertyDescriptors,
                                $ScopeObject);
}

1;

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
(for automatically generated Jobs this would be the batch user). There are many
paths that can result in the creation of a job:

=over

=item *
A use submits a patch or binary to test.

=item *
WineTestBot finds a patch to test on the mailing list (and has all the pieces
it needs for that patch, see WineTestBot::PendingPatchSet).

=item *
WineTestBot notices a Wine commit round and decides to run the full suite of
tests. In this case there is no WineTestBot::Patch object associated with the
Job.

=back

A Job is composed of multiple WineTestBot::Step objects.

=cut

use File::Path;

use WineTestBot::Config;
use WineTestBot::Branches;
use WineTestBot::Engine::Notify;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub _initialize($$)
{
  my ($self, $Collection) = @_;

  $self->SUPER::_initialize($Collection);

  $self->{OldStatus} = undef;
}

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->Archived(!1);
  $self->Branch(CreateBranches()->GetDefaultBranch());
  $self->Status("queued");
  $self->Submitted(time());

  $self->SUPER::InitializeNew($Collection);
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

  my (%Has, $Skip);
  my @SortedSteps = sort { $a->No <=> $b->No } @{$self->Steps->GetItems()};
  foreach my $Step (@SortedSteps)
  {
    my $StepStatus = $Step->UpdateStatus($Skip);
    $Has{$StepStatus} = 1;

    if ($StepStatus ne "queued" && $StepStatus ne "running" &&
        $StepStatus ne "completed" &&
        ($Step->Type eq "build" || $Step->Type eq "reconfig"))
    {
      # The following steps need binaries that this one was supposed to
      # produce. So skip them.
      $Skip = 1;
    }
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
      $self->Save();
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

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::DetailrefPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use ObjectModel::PropertyDescriptor;
use WineTestBot::WineTestBotObjects;
use WineTestBot::Branches;
use WineTestBot::Config;
use WineTestBot::Patches;
use WineTestBot::RecordGroups;
use WineTestBot::Steps;
use WineTestBot::Users;
use WineTestBot::VMs;

use vars qw(@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateJobs &ScheduleJobs &CheckJobs);

my @PropertyDescriptors;

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Id", "Job id", 1, 1, "S",  5),
    CreateBasicPropertyDescriptor("Archived", "Job is archived", !1, 1, "B", 1),
    CreateItemrefPropertyDescriptor("Branch", "Branch", !1, 1, \&CreateBranches, ["BranchName"]),
    CreateItemrefPropertyDescriptor("User", "Author", !1, 1, \&WineTestBot::Users::CreateUsers, ["UserName"]),
    CreateBasicPropertyDescriptor("Priority", "Priority", !1, 1, "N", 1),
    CreateEnumPropertyDescriptor("Status", "Status", !1, 1, ['queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled']),
    CreateBasicPropertyDescriptor("Remarks", "Remarks", !1, !1, "A", 128),
    CreateBasicPropertyDescriptor("Submitted", "Submitted", !1, !1, "DT", 19),
    CreateBasicPropertyDescriptor("Ended", "Ended", !1, !1, "DT", 19),
    CreateItemrefPropertyDescriptor("Patch", "Submitted from patch", !1, !1, \&WineTestBot::Patches::CreatePatches, ["PatchId"]),
    CreateDetailrefPropertyDescriptor("Steps", "Steps", !1, !1, \&CreateSteps),
  );
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Job->new($self);
}

sub CreateJobs(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::Jobs->new("Jobs", "Jobs", "Job", \@PropertyDescriptors,
                                $ScopeObject);
}

sub CompareJobPriority
{
  # Process Jobs with a higher Priority value last (it's a niceness in fact),
  # and older Jobs first.
  return $a->Priority <=> $b->Priority || $a->Id <=> $b->Id;
}

=pod
=over 12

=item C<CheckJobs()>

Goes through the list of Jobs and updates their status. As a side-effect this
detects failed builds, dead child processes, etc.

=back
=cut

sub CheckJobs()
{
  my $Jobs = CreateJobs();
  $Jobs->AddFilter("Status", ["queued", "running"]);
  map { $_->UpdateStatus(); } @{$Jobs->GetItems()};

  return undef;
}

sub min(@)
{
  my $m = shift @_;
  map { $m = $_ if ($_ < $m) } (@_);
  return $m;
}

sub _GetSchedHost($$)
{
  my ($Sched, $VM) = @_;

  my $HostKey = $VM->GetHost();
  if (!$Sched->{hosts}->{$HostKey})
  {
    $Sched->{hosts}->{$HostKey} = {
      active => 0,
      idle => 0,
      reverting => 0,
      sleeping => 0,
      running => 0,
      dirty => 0,
      MaxRevertingVMs => $MaxRevertingVMs,
      MaxRevertsWhileRunningVMs => $MaxRevertsWhileRunningVMs,
      MaxActiveVMs => $MaxActiveVMs,
      MaxVMsWhenIdle => $MaxVMsWhenIdle,
    };
  }
  return $Sched->{hosts}->{$HostKey};
}

sub _GetMaxReverts($)
{
  my ($Host) = @_;
  return ($Host->{running} > 0) ?
         $Host->{MaxRevertsWhileRunningVMs} :
         $Host->{MaxRevertingVMs};
}

=pod
=over 12

=item C<_CanScheduleOnVM()>

Checks if a task or VM operation can be performed on the specified VM.

=back
=cut

sub _CanScheduleOnVM($$)
{
  my ($Sched, $VM) = @_;

  return 1 if ($VM->Status eq "off");

  # If the VM is busy it cannot be taken over for a new task
  my $VMKey = $VM->GetKey();
  return 0 if ($Sched->{busyvms}->{$VMKey});

  # A process may be working on the VM even though it is not busy (e.g. if it
  # is sleeping). In that case just wait.
  return !$VM->ChildPid;
}

=pod
=over 12

=item C<_CheckAndClassifyVMs()>

Checks the VMs state consistency, counts the VMs in each state and classifies
them.

=over

=item *

Checks that each VM's state is consistent and fixes the VM state if not. For
instance, if Status == running then the VM should have a child process. If
there is no such process, or if it died, then the VM should be brought back
to a coherent state, typically by marking it dirty so it is either powered off
or reverted.

=item *

Counts the VMs in each state so the scheduler can respect the limits put on the
number of simultaneous active VMs, reverting VMs, and so on.

=item *

Puts the VMs in one of three sets:
- The set of busyvms.
  This is the set of VMs that are doing something important, for instance
  running a Task, and should not be messed with.
- The set of lambvms.
  This is the set of VMs that use resources (they are powered on), but are
  not doing anything important (idle, sleeping and dirty VMs). If the scheduler
  is hitting the limits but still needs to power on one more VM, it can power
  off one of these to make room.
- The set of powered off VMs.
  These are the VMs which are in neither the busyvms nor the lambvms set. Since
  they are powered off they are not using resources.

=item *

Each VM is given a priority describing the likelihood that it will be needed
by a future job. When no other VM is running this can be used to decide which
VMs to start in advance.

=back

=back
=cut

sub _CheckAndClassifyVMs()
{
  my $Sched = {
    VMs => CreateVMs(),
    hosts => {},
    busyvms => {},
    lambvms=> {},
    nicefuture => {},
    runnable => 0,
    queued => 0,
    recordgroups => CreateRecordGroups(),
  };
  $Sched->{recordgroup} = $Sched->{recordgroups}->Add();
  $Sched->{records} = $Sched->{recordgroup}->Records;
  # Save the new RecordGroup now so its Id is lower than those of the groups
  # created by the scripts called from the scheduler.
  $Sched->{recordgroups}->Save();

  my $FoundVMErrors;
  # Count the VMs that are 'active', that is, that use resources on the host,
  # and those that are reverting. Also build a prioritized list of those that
  # are ready to run tests: the idle ones.
  foreach my $VM (@{$Sched->{VMs}->GetItems()})
  {
    my $VMKey = $VM->GetKey();
    if (!$VM->HasEnabledRole())
    {
      # Don't schedule anything on this VM and otherwise ignore it
      $Sched->{busyvms}->{$VMKey} = 1;
      next;
    }

    my $Host = _GetSchedHost($Sched, $VM);
    if ($VM->HasRunningChild())
    {
      if ($VM->Status =~ /^(?:dirty|running|reverting)$/)
      {
        $Sched->{busyvms}->{$VMKey} = 1;
        $Host->{$VM->Status}++;
        $Host->{active}++;
      }
      elsif ($VM->Status eq "sleeping")
      {
        # Note that in the case of powered off VM snapshots, a sleeping VM is
        # in fact booting up thus taking CPU and I/O resources.
        # So don't count it as idle.
        $Sched->{lambvms}->{$VMKey} = 1;
        $Host->{sleeping}++;
        $Host->{active}++;
      }
      elsif ($VM->Status eq "offline")
      {
        # The VM cannot be used until it comes back online
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      elsif ($VM->Status eq "maintenance")
      {
        # Maintenance VMs should not have a child process!
        $FoundVMErrors = 1;
        $VM->KillChild();
        $VM->Save();
        $VM->RecordResult($Sched->{records}, "boterror unexpected process");
        # And the scheduler should not touch them
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      elsif ($VM->Status =~ /^(?:idle|off)$/)
      {
        # idle and off VMs should not have a child process!
        # Mark the VM dirty so a poweroff or revert brings it to a known state.
        $FoundVMErrors = 1;
        $VM->KillChild();
        $VM->Status("dirty");
        $VM->Save();
        $VM->RecordResult($Sched->{records}, "boterror unexpected process");
        $Sched->{lambvms}->{$VMKey} = 1;
        $Host->{dirty}++;
        $Host->{active}++;
      }
      else
      {
        require WineTestBot::Log;
        WineTestBot::Log::LogMsg("Unexpected $VMKey status ". $VM->Status ."\n");
        $FoundVMErrors = 1;
        # Don't interfere with this VM
        $Sched->{busyvms}->{$VMKey} = 1;
      }
    }
    else
    {
      if (defined $VM->ChildPid or
          $VM->Status =~ /^(?:running|reverting|sleeping)$/)
      {
        # The VM is missing its child process or it died unexpectedly. Mark
        # the VM dirty so a revert or shutdown brings it back to a known state.
        $FoundVMErrors = 1;
        $VM->ChildPid(undef);
        $VM->Status("dirty");
        $VM->Save();
        $VM->RecordResult($Sched->{records}, "boterror process died");
        $Sched->{lambvms}->{$VMKey} = 1;
        $Host->{dirty}++;
        $Host->{active}++;
      }
      elsif ($VM->Status =~ /^(?:dirty|idle)$/)
      {
        $Sched->{lambvms}->{$VMKey} = 1;
        $Host->{$VM->Status}++;
        $Host->{active}++;
      }
      elsif ($VM->Status eq "offline")
      {
        my $ErrMessage = $VM->RunMonitor();
        return ($ErrMessage, undef) if (defined $ErrMessage);
        # Ignore the VM for this round since we cannot use it
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      elsif ($VM->Status eq "maintenance")
      {
        # Don't touch the VM while the administrator is working on it
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      elsif ($VM->Status ne "off")
      {
        require WineTestBot::Log;
        WineTestBot::Log::LogMsg("Unexpected $VMKey status ". $VM->Status ."\n");
        $FoundVMErrors = 1;
        # Don't interfere with this VM
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      # Note that off VMs are neither in busyvms nor lambvms
    }

    $Sched->{nicefuture}->{$VMKey} =
        ($VM->Role eq "base" ? 0 :
         $VM->Role eq "winetest" ? 10 :
         20) + # extra
        ($VM->Type eq "build" ? 0 :
         $VM->Type eq "win64" ? 1 :
         2); # win32
  }

  # If a VM was in an inconsistent state, update the jobs status fields before
  # continuing with the scheduling.
  CheckJobs() if ($FoundVMErrors);

  return (undef, $Sched);
}

=pod
=over 12

=item C<_AddNeededVM()>

Adds the specified VM to the list of VMs needed by queued tasks, together with
priority information. The priority information is stored in an array which
contains:

=over

=item [0]

The VM's position in the Jobs list. Newer jobs give precedence to older ones.
Note that the position within a job ($Step->No and $Task->No) does not matter.
What counts is getting the job results to the developer.

=item [1]

The VM Status: dirty VMs are given a small priority boost since they are
likely to already be in the host's memory.

=item [2]

The number of Tasks that need the VM. Give priority to VMs that are needed by
more Tasks so we don't end up in a situation where all the tasks need the same
VM, which cannot be parallelized.

=item [3]

If the VM is needed for a 'next step', then this lists its dependencies.
The dependencies are the VMs that are still needed by a task in the current
step. If any VM in the dependencies list is not yet being prepared to run
a task, then it is too early to start preparing this VM for the next step.

=back

=back
=cut

sub _AddNeededVM($$$;$)
{
  my ($NeededVMs, $VM, $Niceness, $Dependencies) = @_;

  my $VMKey = $VM->GetKey();
  if (!$NeededVMs->{$VMKey})
  {
    my $Hot = ($VM->Status ne "off") ? 1 : 0;
    my $PendingReverts = ($VM->Status !~ /^(?:idle|reverting|sleeping)$/) ? 1 : 0;
    $NeededVMs->{$VMKey} = [$Niceness, $Hot, $PendingReverts, $Dependencies];
    return 1;
  }

  # One more task needs this VM
  $NeededVMs->{$VMKey}->[2]++;

  # Although we process the jobs in decreasing priority order, the VM may
  # have been added for a 'next step' task and thus with a much increased
  # niceness and dependencies compared to the jobs that follow.
  if ($Niceness < $NeededVMs->{$VMKey}->[0])
  {
    $NeededVMs->{$VMKey}->[0] = $Niceness;
    $NeededVMs->{$VMKey}->[3] = $Dependencies;
    return 1;
  }

  return 0;
}

sub _GetNiceness($$)
{
  my ($NeededVMs, $VMKey) = @_;
  return $NeededVMs->{$VMKey}->[0];
}

sub _CompareNeededVMs($$$)
{
  my ($NeededVMs, $VMKey1, $VMKey2) = @_;

  my $Data1 = $NeededVMs->{$VMKey1};
  my $Data2 = $NeededVMs->{$VMKey2};
  return $Data1->[0] <=> $Data2->[0] || # Lower niceness jobs first
         $Data2->[1] <=> $Data1->[1] || # Hot VMs first
         $Data2->[2] <=> $Data1->[2];   # Needed by more tasks first
}

sub _HasMissingDependencies($$$)
{
  my ($Sched, $NeededVMs, $VMKey) = @_;

  my $Data = $NeededVMs->{$VMKey};
  return undef if (!$Data->[3]);

  foreach my $DepVM (@{$Data->[3]})
  {
    return 1 if ($DepVM->Status !~ /^(?:reverting|sleeping|running)$/);
  }
  return undef;
}

my $NEXT_BASE = 1000;
my $FUTURE_BASE = 2000;

=pod
=over 12

=item C<_ScheduleTasks()>

Runs the tasks on idle VMs, and builds a list of the VMs that will be needed
next.

=back
=cut

sub _ScheduleTasks($)
{
  my ($Sched) = @_;

  # The set of VMs needed by the runnable, 'next step' and future tasks
  my $NeededVMs = {};

  # Process the jobs in decreasing priority order
  my $JobRank;
  my $Jobs = CreateJobs($Sched->{VMs});
  $Jobs->AddFilter("Status", ["queued", "running"]);
  foreach my $Job (sort CompareJobPriority @{$Jobs->GetItems()})
  {
    $JobRank++;

    # The list of VMs that should be getting ready to run
    # before we prepare the next step
    my $PreviousVMs = [];

    my $StepRank = 0;
    my $Steps = $Job->Steps;
    $Steps->AddFilter("Status", ["queued", "running"]);
    foreach my $Step (sort { $a->No <=> $b->No } @{$Steps->GetItems()})
    {
      my $Tasks = $Step->Tasks;
      $Tasks->AddFilter("Status", ["queued"]);
      $Sched->{queued} += $Tasks->GetItemsCount();

      # StepRank 0 contains the runnable tasks, 1 the 'may soon be runnable'
      # ones, and 2 and greater tasks we don't care about yet
      next if ($StepRank >= 2);
      if ($StepRank == 0)
      {
        $Step->HandleStaging() if ($Step->Status eq "queued");
        $Sched->{runnable} += $Tasks->GetItemsCount();
      }
      elsif (!$PreviousVMs)
      {
        # The previous step is nowhere near done so skip this one for now
        next;
      }

      my $StepVMs = [];
      foreach my $Task (@{$Tasks->GetItems()})
      {
        my $VM = $Task->VM;
        next if (!$VM->HasEnabledRole() or !$VM->HasEnabledStatus());

        if ($StepRank == 1)
        {
          # Passing $PreviousVMs ensures this VM will be reverted if and only
          # if all of the previous step's tasks are about to run.
          # See _HasMissingDependencies().
          _AddNeededVM($NeededVMs, $VM, $NEXT_BASE + $JobRank, $PreviousVMs);
          next;
        }

        if (!_AddNeededVM($NeededVMs, $VM, $JobRank))
        {
          # This VM is in $NeededVMs already which means it is already
          # scheduled to be reverted for a task with a higher priority.
          # So this task won't be run before a while and thus there is
          # no point in preparing the next step.
          $StepVMs = undef;
          next;
        }

        # It's not worth preparing the next step for tasks that take so long
        $StepVMs = undef if ($Task->Timeout > $BuildTimeout);

        my $VMKey = $VM->GetKey();
        if ($VM->Status eq "idle")
        {
          # Most of the time reverting a VM takes longer than running a task.
          # So if a VM is ready (i.e. idle) we can start the first task we
          # find for it, even if we could revert another VM to run a higher
          # priority job.
          # Even if we cannot start the task right away this VM is not a
          # candidate for shutdown since it will be needed next.
          delete $Sched->{lambvms}->{$VMKey};

          my $Host = _GetSchedHost($Sched, $VM);
          if ($Host->{active} - $Host->{idle} < $Host->{MaxActiveVMs} and
              ($Host->{reverting} == 0 or
               $Host->{reverting} <= $Host->{MaxRevertsWhileRunningVMs}))
          {
            $Sched->{busyvms}->{$VMKey} = 1;
            $VM->RecordStatus($Sched->{records}, join(" ", "running", $Job->Id, $Step->No, $Task->No));
            my $ErrMessage = $Task->Run($Step);
            return ($ErrMessage, undef) if (defined $ErrMessage);

            $Job->UpdateStatus();
            $Host->{idle}--;
            $Host->{running}++;
          }
        }
        elsif ($VM->Status =~ /^(?:reverting|sleeping)$/)
        {
          # The VM is not running jobs yet but soon will be so it is not a
          # candidate for shutdown or sacrifices.
          delete $Sched->{lambvms}->{$VMKey};
        }
        elsif ($VM->Status ne "off" and !$Sched->{lambvms}->{$VMKey})
        {
          # We cannot use the VM because it is busy (running another task,
          # offline, etc.). So it is too early to prepare the next step.
          $StepVMs = undef;
        }
        push @$StepVMs, $VM if ($StepVMs);
      }
      $PreviousVMs = $StepVMs;
      $StepRank++;
    }
  }

  # Finally add some VMs with a very low priority for future jobs.
  foreach my $VM (@{$Sched->{VMs}->GetItems()})
  {
    next if (!$VM->HasEnabledRole() or !$VM->HasEnabledStatus());
    my $VMKey = $VM->GetKey();
    my $Niceness = $FUTURE_BASE + $Sched->{nicefuture}->{$VMKey};
    _AddNeededVM($NeededVMs, $VM, $Niceness);
  }

  return (undef, $NeededVMs);
}

=pod
=over 12

=item C<_SacrificeVM()>

Looks for and powers off a VM we don't need now in order to free resources
for one we do need now.

This is a helper for _RevertVMs().

=back
=cut

sub _SacrificeVM($$$)
{
  my ($Sched, $NeededVMs, $VM) =@_;
  my $VMKey = $VM->GetKey();
  my $Host = _GetSchedHost($Sched, $VM);

  # Grab the lowest priority lamb and sacrifice it
  my $ForFutureVM = (_GetNiceness($NeededVMs, $VMKey) >= $FUTURE_BASE);
  my $NiceFuture = $Sched->{nicefuture};
  my ($Victim, $VictimKey, $VictimStatusPrio);
  foreach my $CandidateKey (keys %{$Sched->{lambvms}})
  {
    my $Candidate = $Sched->{VMs}->GetItem($CandidateKey);

    # Check that the candidate is on the right host
    my $CandidateHost = _GetSchedHost($Sched, $Candidate);
    next if ($CandidateHost != $Host);

    # Don't sacrifice idle / sleeping VMs for future tasks
    next if ($ForFutureVM and $Candidate->Status =~ /^(?:idle|sleeping)/);

    # Don't sacrifice more important VMs
    next if (_CompareNeededVMs($NeededVMs, $CandidateKey, $VMKey) <= 0);

    my $CandidateStatusPrio = $Candidate->Status eq "idle" ? 2 :
                              $Candidate->Status eq "sleeping" ? 1 :
                              0; # Status eq dirty
    if ($Victim)
    {
      my $Cmp = $VictimStatusPrio <=> $CandidateStatusPrio ||
                $NiceFuture->{$CandidateKey} <=> $NiceFuture->{$VictimKey};
      next if ($Cmp <= 0);
    }

    $Victim = $Candidate;
    $VictimKey = $CandidateKey;
    $VictimStatusPrio = $CandidateStatusPrio;
  }
  return undef if (!$Victim);

  delete $Sched->{lambvms}->{$VictimKey};
  $Sched->{busyvms}->{$VictimKey} = 1;
  $Host->{$Victim->Status}--;
  $Host->{dirty}++;
  $Victim->RecordStatus($Sched->{records}, $Victim->Status eq "dirty" ? "dirty poweroff" : "dirty sacrifice");
  $Victim->RunPowerOff();
  return 1;
}

sub _RevertVMs($$)
{
  my ($Sched, $NeededVMs) = @_;

  # Sort the VMs that tasks need by decreasing priority order and revert them
  my @SortedNeededVMs = sort { _CompareNeededVMs($NeededVMs, $a, $b) } keys %{$NeededVMs};
  foreach my $VMKey (@SortedNeededVMs)
  {
    my $VM = $Sched->{VMs}->GetItem($VMKey);
    my $VMStatus = $VM->Status;
    next if ($VMStatus eq "idle");

    # Check if the host has reached its reverting VMs limit
    my $Host = _GetSchedHost($Sched, $VM);
    next if ($Host->{reverting} >= _GetMaxReverts($Host));

    # Skip this VM if the previous step's tasks are not about to run yet
    next if (_HasMissingDependencies($Sched, $NeededVMs, $VMKey));
    next if (!_CanScheduleOnVM($Sched, $VM));

    my $NeedsSacrifice;
    if (_GetNiceness($NeededVMs, $VMKey) >= $FUTURE_BASE)
    {
      if (!exists $Host->{isidle})
      {
        # Only start preparing VMs for future jobs on a host which is idle.
        # FIXME As a proxy we currently check that the host only has idle VMs.
        # This is a bad proxy because:
        # - The host could still have pending tasks for a 'next step'. Once
        #   those get closer to running, preparing those would be better than
        #   preparing future VMs.
        # - Checking there are no queued tasks on that host would be better
        #   but this information is not available on a per-host basis.
        # - Also the number of queued tasks includes tasks scheduled to run
        #   on maintenance and retired/deleted VMs. Any such task would prevent
        #   preparing future VMs for no good reason.
        # - It forces the host to go through an extra poweroff during which we
        #   lose track of which VM is 'hot'.
        # - However on startup this helps ensure that we are not prevented
        #   from preparing the best VM (e.g. build) just because it is still
        #   being checked (i.e. marked dirty).
        $Host->{isidle} = ($Host->{active} == $Host->{idle});
      }
      if (!$Host->{isidle} or $Host->{MaxVMsWhenIdle} == 0)
      {
        # The TestBot is busy or does not prepare VMs when idle
        next;
      }
      # To not exceed the limit we must take into account VMs that are not yet
      # idle but will soon be.
      my $FutureIdle = $Host->{idle} + $Host->{reverting} + $Host->{sleeping} + ($VMStatus eq "off" ? 1 : 0);
      $NeedsSacrifice = ($FutureIdle > $Host->{MaxVMsWhenIdle});
    }
    else
    {
      my $FutureActive = $Host->{active} + ($VMStatus eq "off" ? 1 : 0);
      $NeedsSacrifice = ($FutureActive > $Host->{MaxActiveVMs});
    }

    if ($NeedsSacrifice)
    {
      # Find an active VM to sacrifice so we can revert this VM in the next
      # scheduler round
      last if (!_SacrificeVM($Sched, $NeededVMs, $VM));
      delete $Sched->{lambvms}->{$VMKey};
      # The $Host counters must account for the coming revert. This means
      # active is unchanged: -1 for the sacrificed VM and +1 for the revert.
      $Host->{reverting}++;
    }
    else
    {
      delete $Sched->{lambvms}->{$VMKey};
      $Sched->{busyvms}->{$VMKey} = 1;
      my $ErrMessage = $VM->RunRevert();
      return $ErrMessage if (defined $ErrMessage);
      $Host->{active}++ if ($VMStatus eq "off");
      $Host->{reverting}++;
    }
  }
  return undef;
}

sub _PowerOffDirtyVMs($)
{
  my ($Sched) = @_;

  # Power off any still dirty VM
  foreach my $VMKey (keys %{$Sched->{lambvms}})
  {
    my $VM = $Sched->{VMs}->GetItem($VMKey);
    next if ($VM->Status ne "dirty");

    $VM->RecordStatus($Sched->{records}, "dirty poweroff");
    my $ErrMessage = $VM->RunPowerOff();
    return $ErrMessage if (defined $ErrMessage);
  }
  return undef;
}

my $_LastTaskCounts = "";

=pod
=over 12

=item C<ScheduleJobs()>

Goes through the pending Jobs to run their queued Tasks. This implies preparing
the VMs while staying within the VM hosts resource limits. In particular this
means taking the following constraints into account:

=over

=item *

Jobs should be run in decreasing order of priority.

=item *

A Job's Steps must be run in sequential order.

=item *

A Step's tasks can be run in parallel but only one task can be running in a VM
at a given time. Also a VM must be prepared before it can run its task, see the
VM Statuses.

=item *

The number of active VMs on the host must be kept under $MaxActiveVMs. Any
VM using resources counts as an active VM, including those that are being
reverted. This limit is meant to ensure the VM host will have enough memory,
CPU or I/O resources for all the active VMs. Also note that this limit must be
respected even if there is more than one hypervisor running on the host.

=item *

The number of VMs being reverted on the host at a given time must be kept under
$MaxRevertingVMs, or $MaxRevertsWhileRunningVMs if some VMs are currently
running tests. This may be set to 1 in case the hypervisor gets confused when
reverting too many VMs at once.

=item *

Once there are no jobs to run anymore the scheduler can prepare up to
$MaxVMsWhenIdle VMs (or $MaxActiveVMs if not set) for future jobs.
This can be set to 0 to minimize the TestBot resource usage when idle.
This can also be set to a value greater than $MaxActiveVMs. Then only
$MaxActiveVMs tasks will be run simultaneously but the extra idle VMs will be
kept on standby so they are ready when their turn comes.

=back

=back
=cut

sub ScheduleJobs()
{
  my ($ErrMessage, $Sched) = _CheckAndClassifyVMs();
  return $ErrMessage if ($ErrMessage);

  my $NeededVMs;
  ($ErrMessage, $NeededVMs) = _ScheduleTasks($Sched);
  return $ErrMessage if ($ErrMessage);

  $ErrMessage = _RevertVMs($Sched, $NeededVMs);
  return $ErrMessage if ($ErrMessage);

  $ErrMessage = _PowerOffDirtyVMs($Sched);
  return $ErrMessage if ($ErrMessage);

  # Note that any VM Status or Role change will trigger ScheduleJobs() so this
  # records all not yet recorded VM state changes, even those not initiated by
  # the scheduler.
  map { $_->RecordStatus($Sched->{records}) } @{$Sched->{VMs}->GetItems()};

  if (@{$Sched->{records}->GetItems()})
  {
    # FIXME Add the number of tasks scheduled to run on a maintenance, retired
    #       or deleted VM...
    my $TaskCounts = "$Sched->{runnable} $Sched->{queued} 0";
    if ($TaskCounts ne $_LastTaskCounts)
    {
      $Sched->{records}->AddRecord('tasks', 'counters', $TaskCounts);
      $_LastTaskCounts = $TaskCounts;
    }
    $Sched->{recordgroups}->Save();
  }
  else
  {
    $Sched->{recordgroups}->DeleteItem($Sched->{recordgroup});
  }

  return undef;
}

sub FilterNotArchived($)
{
  my ($self) = @_;

  $self->AddFilter("Archived", [!1]);
}

1;

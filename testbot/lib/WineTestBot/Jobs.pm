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

  my $JobDir = "$DataDir/jobs/" . $self->Id;
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
        system("rm", "-rf", "$JobDir/" . $Step->No . "/" . $Task->No);
      }
      $Task->Status("queued");
      $Task->Started(undef);
      $Task->Ended(undef);
      $Task->TestFailures(undef);
    }
    # Subsequent steps only contain files generated by the previous steps
    system("rm", "-rf", "$JobDir/" . $Step->No) if (!$FirstStep);
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

sub min(@)
{
  my $m = shift @_;
  map { $m = $_ if ($_ < $m) } (@_);
  return $m;
}

=pod
=over 12

=item C<_CanScheduleOnVM()>

Checks if a task or VM operation can be performed on the specified VM.

We allow multiple VM instances to refer to different snapshots of the same
hypervisor domain (that is VM objects that have identical VirtURI and
VirtDomain fields but different values for IdleSnapshot). This is typically
used to test different configurations of the same base virtual machine.

However a hypervisor domain cannot run two snapshots simultaneously so this
function is used to ensure the scheduler does not simultaneously assign the
same hypervisor domain to two VM instances.

=back
=cut

sub _CanScheduleOnVM($$;$)
{
  my ($Sched, $VM, $Steal) = @_;

  my $DomainKey = $VM->VirtURI ." ". $VM->VirtDomain;
  my $DomainVM = $Sched->{domains}->{$DomainKey};

  if (!$DomainVM or $DomainVM->Status eq "off")
  {
    $Sched->{domains}->{$DomainKey} = $VM;
    return 1;
  }

  my $VMKey = $VM->GetKey();
  if ($Sched->{busyvms}->{$VMKey})
  {
    # If the VM is busy it cannot be taken over for a new task
    return 0;
  }

  my $DomainVMKey = $DomainVM->GetKey();
  if ($VMKey eq $DomainVMKey and !$VM->ChildPid)
  {
    # Already ours and not busy
    return 1;
  }

  # We cannot schedule anything on this VM if we cannot take the hypervisor
  # domain from its current owner. Note that we can always take over dirty VMs
  # if we did not start an operation on them yet (i.e. if they are in lambvms).
  if (!$Sched->{lambvms}->{$DomainVMKey} or
      (!$Steal and $DomainVM->Status ne "dirty"))
  {
    return 0;
  }

  # $DomainVM is either dirty (with no child process), idle or sleeping.
  # Just mark it off and let the caller poweroff or revert the
  # hypervisor domain as needed for the new VM.
  $DomainVM->KillChild(); # For the sleeping case
  $Sched->{$DomainVM->Status}--;
  $Sched->{active}--;
  $DomainVM->Status("off");
  $DomainVM->Save();
  # off VMs are neither in busyvms nor lambvms
  delete $Sched->{lambvms}->{$DomainVMKey};
  $Sched->{domains}->{$DomainKey} = $VM;
  return 1;
}

=pod
=over 12

=item C<_SacrificeVM()>

Looks for and powers off a VM we don't need now in order to free resources
for one we do need now.

=back
=cut

sub _SacrificeVM($$)
{
  my ($Sched, $HostVMs) =@_;

  # Grab the lowest priority lamb and sacrifice it
  my $Priorities = $Sched->{vmpriorities};
  my ($Victim, $VictimKey, $VictimStatusPrio);
  foreach my $VMKey (keys %{$Sched->{lambvms}})
  {
    my $VM = $HostVMs->GetItem($VMKey);
    my $VMStatusPrio = $VM->Status eq "idle" ? 2 :
                       $VM->Status eq "sleeping" ? 1 :
                       0; # Status eq dirty

    if ($Victim)
    {
      my $Cmp = $VictimStatusPrio <=> $VMStatusPrio ||
                $Priorities->{$VictimKey} <=> $Priorities->{$VMKey};
      next if ($Cmp < 0);
    }

    $Victim = $VM;
    $VictimKey = $VMKey;
    $VictimStatusPrio = $VMStatusPrio;
  }
  return undef if (!$Victim);

  delete $Sched->{lambvms}->{$VictimKey};
  $Sched->{busyvms}->{$VictimKey} = 1;
  $Sched->{$Victim->Status}--;
  $Sched->{dirty}++;
  $Victim->RunPowerOff();
  return 1;
}

sub _GetCounters($)
{
  my ($Sched) = @_;
  my $Msg = "";
  for my $counter ("active", "idle", "reverting", "sleeping", "running", "dirty")
  {
    $Msg .= " $counter=". $Sched->{$counter} if ($Sched->{$counter});
  }
  $Msg =~ s/^ //;
  return $Msg;
}

=pod
=over 12

=item C<_CheckAndClassifyVMs()>

Checks the VMs state consistency, counts the VMs in each state, classifies
them, and determines which VM owns each hypervisor domain.

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

Determines which VM should have exclusive access to each hypervisor domain.
This is normally the VM that is currently using it, but if all a given
hypervisor domain's VMs are off, one of them is picked at random. In any case
if a VM is not in the busyvms set, the hypervisor domain can be taken away from
it if necessary.

=item *

Each VM is given a priority describing the likelyhood that it will be needed
by a future job. When no other VM is running this can be used to decide which
VMs to start in advance.

=cut

=back
=cut

sub _CheckAndClassifyVMs($)
{
  my ($HostVMs) = @_;

  my $Sched = {active => 0,
               idle => 0,
               reverting => 0,
               sleeping => 0,
               running => 0,
               dirty => 0,
               busyvms => {},
               lambvms=> {},
               vmpriorities => {},
  };

  # Count the VMs that are 'active', that is, that use resources on the host,
  # and those that are reverting. Also build a prioritized list of those that
  # are ready to run tests: the idle ones.
  foreach my $VM (@{$HostVMs->GetItems()})
  {
    my $VMKey = $VM->GetKey();
    if ($VM->HasRunningChild())
    {
      if ($VM->Status =~ /^(?:dirty|running|reverting)$/)
      {
        $Sched->{busyvms}->{$VMKey} = 1;
        $Sched->{$VM->Status}++;
        $Sched->{active}++;
      }
      elsif ($VM->Status eq "sleeping")
      {
        # Note that in the case of powered off VM snapshots, a sleeping VM is
        # in fact booting up thus taking CPU and I/O resources.
        # So don't count it as idle.
        $Sched->{lambvms}->{$VMKey} = 1;
        $Sched->{sleeping}++;
        $Sched->{active}++;
      }
      elsif ($VM->Status eq "offline")
      {
        # The VM cannot be used until it comes back online
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      elsif ($VM->Status eq "maintenance")
      {
        # Maintenance VMs should not have a child process!
        $VM->KillChild();
        $VM->Save();
        # And the scheduler should not touch them
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      elsif ($VM->Status =~ /^(?:idle|off)$/)
      {
        # idle and off VMs should not have a child process!
        # Mark the VM dirty so a poweroff or revert brings it to a known state.
        # Note: The revert or poweroff will save the VM object.
        $VM->KillChild();
        $VM->Status("dirty");
        $Sched->{lambvms}->{$VMKey} = 1;
        $Sched->{dirty}++;
        $Sched->{active}++;
      }
      else
      {
        require WineTestBot::Log;
        WineTestBot::Log::LogMsg("Unexpected $VMKey status ". $VM->Status ."\n");
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
        # Note: The revert or poweroff will save the VM object.
        $VM->ChildPid(undef);
        $VM->Status("dirty");
        $Sched->{lambvms}->{$VMKey} = 1;
        $Sched->{dirty}++;
        $Sched->{active}++;
      }
      elsif ($VM->Status =~ /^(?:dirty|idle)$/)
      {
        $Sched->{lambvms}->{$VMKey} = 1;
        $Sched->{$VM->Status}++;
        $Sched->{active}++;
      }
      elsif ($VM->Status eq "offline")
      {
        # Ignore the VM for this round since we cannot use it
        $Sched->{busyvms}->{$VMKey} = 1;
        if (_CanScheduleOnVM($Sched, $VM))
        {
          my $ErrMessage = $VM->RunMonitor();
          return ($ErrMessage, undef) if (defined $ErrMessage);
        }
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
        # Don't interfere with this VM
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      # Note that off VMs are neither in busyvms nor lambvms
    }

    _CanScheduleOnVM($Sched, $VM);

    my $Priority = $VM->Type eq "build" ? 100 :
                   $VM->Role ne "base" ? 1 :
                   $VM->Type eq "win32" ? 10 :
                   20; # win64
    $Sched->{vmpriorities}->{$VMKey} = $Priority;
  }

  return (undef, $Sched);
}

my $NEXT_BASE = 1000;

=pod
=over 12

=item C<ScheduleOnHost()>

This manages the VMs and WineTestBot::Task objects corresponding to the
hypervisors of a given host. To stay within the host's resource limits the
scheduler must take the following constraints into account:
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

The number of active VMs on the host must be kept under $MaxActiveVMs. This
includes any VM using resources, including those that are being reverted. The
rational behind this limit is that the host may not be able to run more VMs
simultaneously, typically due to memory or CPU constraints. Also note that
this limit must be respected even if there is more than one hypervisor running
on the host.

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

=cut

=back
=cut

sub ScheduleOnHost($$$)
{
  my ($ScopeObject, $SortedJobs, $Hypervisors) = @_;

  my $HostVMs = CreateVMs($ScopeObject);
  $HostVMs->FilterEnabledRole();
  $HostVMs->FilterHypervisors($Hypervisors);

  my ($ErrMessage, $Sched) = _CheckAndClassifyVMs($HostVMs);
  return $ErrMessage if ($ErrMessage);

  # Then we build a prioritized list of VMs to revert.
  my %VMsToRevert;
  my $RevertNiceness;
  foreach my $Job (@$SortedJobs)
  {
    my $Steps = $Job->Steps;
    $Steps->AddFilter("Status", ["queued", "running"]);
    my @SortedSteps = sort { $a->No <=> $b->No } @{$Steps->GetItems()};
    if (@SortedSteps != 0)
    {
      my $Step = $SortedSteps[0];
      $Step->HandleStaging($Job->GetKey());
      my $PrepareNextStep;
      my $Tasks = $Step->Tasks;
      $Tasks->AddFilter("Status", ["queued"]);
      my @SortedTasks = sort { $a->No <=> $b->No } @{$Tasks->GetItems()};
      foreach my $Task (@SortedTasks)
      {
        my $VM = $Task->VM;
        my $VMKey = $VM->GetKey();
        next if (!$HostVMs->ItemExists($VMKey) || exists $VMsToRevert{$VMKey});

        # The jobs are sorted by decreasing order of priority. Also, most of
        # the time reverting a VM takes longer than running a Task.
        # So if a VM is ready (i.e. idle) we can start the first task we
        # find for it, even if we could revert another VM to run a higher
        # priority job.
        if ($VM->Status eq "idle")
        {
          # Even if we cannot start the task right away this VM is not a
          # candidate for shutdown since it will be needed next.
          delete $Sched->{lambvms}->{$VMKey};

          # Note that right after the Engine startup _CanScheduleOnVM() may
          # fail despite this VM being idle if the other VMs sharing its
          # domain are still going through checkidle.
          if ($Sched->{active} - $Sched->{idle} < $MaxActiveVMs and
              ($Sched->{reverting} == 0 || $Sched->{reverting} <= $MaxRevertsWhileRunningVMs) and
              _CanScheduleOnVM($Sched, $VM))
          {
            $Sched->{busyvms}->{$VMKey} = 1;
            my $ErrMessage = $Task->Run($Step);
            return $ErrMessage if (defined $ErrMessage);
            $Job->UpdateStatus();
            $Sched->{idle}--;
            $Sched->{running}++;
          }
          $PrepareNextStep = 1;
        }
        elsif ($VM->Status eq "sleeping")
        {
          # It's not running jobs yet but soon will be so it's not a candidate
          # for shutdown or revert and we should prepare the next step.
          delete $Sched->{lambvms}->{$VMKey};
          $PrepareNextStep = 1;
        }
        elsif ($VM->Status eq "off" or $Sched->{lambvms}->{$VMKey})
        {
          $RevertNiceness++;
          $VMsToRevert{$VMKey} ||= $RevertNiceness;
        }
      }
      if ($PrepareNextStep && @SortedSteps >= 2)
      {
        # Build a list of VMs we will need next
        my $Step = $SortedSteps[1];
        $Tasks = $Step->Tasks;
        $Tasks->AddFilter("Status", ["queued"]);
        @SortedTasks = sort { $a->No <=> $b->No } @{$Tasks->GetItems()};
        foreach my $Task (@SortedTasks)
        {
          my $VMKey = $Task->VM->GetKey();
          next if (!$HostVMs->ItemExists($VMKey));
          $RevertNiceness++;
          $VMsToRevert{$VMKey} ||= $NEXT_BASE + $RevertNiceness;
          # If idle already this is not a candidate for shutdown
          delete $Sched->{lambvms}->{$VMKey};
        }
      }
    }
  }

  # Sort the VMs that Tasks need by decreasing priority order and revert them
  my $MaxReverts = ($Sched->{running} > 0) ?
                   $MaxRevertsWhileRunningVMs : $MaxRevertingVMs;
  my @SortedVMsToRevert = sort { $VMsToRevert{$a} <=> $VMsToRevert{$b} } keys %VMsToRevert;
  foreach my $VMKey (@SortedVMsToRevert)
  {
    last if ($Sched->{reverting} >= $MaxReverts);
    last if ($Sched->{active} > $MaxActiveVMs);

    # Don't steal the hypervisor domain for a VM we will only need later
    my $Steal = ($VMsToRevert{$VMKey} < $NEXT_BASE);
    my $VM = $HostVMs->GetItem($VMKey);
    next if (!_CanScheduleOnVM($Sched, $VM, $Steal));
    if ($VM->Status eq "off" and $Sched->{active} == $MaxActiveVMs)
    {
      # Find an active VM to sacrifice so we can revert more VMs in the next
      # scheduler round
      last if (!_SacrificeVM($Sched, $HostVMs));
      delete $Sched->{lambvms}->{$VMKey};
      # $Sched->{active} is unchanged: -1 for the sacrificed VM and +1 for the
      # coming revert
    }
    else
    {
      delete $Sched->{lambvms}->{$VMKey};
      $Sched->{busyvms}->{$VMKey} = 1;
      my $ErrMessage = $VM->RunRevert();
      return $ErrMessage if (defined $ErrMessage);
      $Sched->{active}++ if ($VM->Status eq "off");
    }
    $Sched->{reverting}++;
  }

  # Finally, if we are otherwise idle, prepare some VMs for future jobs
  if ($Sched->{active} == $Sched->{idle} && $Sched->{idle} < $MaxVMsWhenIdle)
  {
    # Sort from most important to least important
    my $Priorities = $Sched->{vmpriorities};
    my @FutureVMs = sort { $Priorities->{$b} <=> $Priorities->{$a} } keys %$Priorities;
    foreach my $VMKey (@FutureVMs)
    {
      last if ($Sched->{reverting} >= $MaxReverts);
      last if ($Sched->{active} >= $MaxVMsWhenIdle);

      my $VM = $HostVMs->GetItem($VMKey);
      next if ($VM->Status !~ /^(?:dirty|off)$/);
      # There is no point stealing idle hypervisor domains here
      next if (!_CanScheduleOnVM($Sched, $VM));

      delete $Sched->{lambvms}->{$VMKey};
      $Sched->{busyvms}->{$VMKey} = 1;
      my $ErrMessage = $VM->RunRevert();
      return $ErrMessage if (defined $ErrMessage);
      $Sched->{reverting}++;
      $Sched->{active}++;
    }
  }

  # Power off any still dirty VM
  foreach my $VMKey (keys %{$Sched->{lambvms}})
  {
    my $VM = $HostVMs->GetItem($VMKey);
    next if ($VM->Status ne "dirty");
    next if (!_CanScheduleOnVM($Sched, $VM));

    my $ErrMessage = $VM->RunPowerOff();
    return $ErrMessage if (defined $ErrMessage);
  }

  return undef;
}

=pod
=over 12

=item C<ScheduleJobs()>

Goes through the WineTestBot hosts and schedules the Job tasks on each of
them using WineTestBot::Jobs::ScheduleOnHost().

=back
=cut

sub ScheduleJobs()
{
  my $Jobs = CreateJobs();
  $Jobs->AddFilter("Status", ["queued", "running"]);
  my @SortedJobs = sort CompareJobPriority @{$Jobs->GetItems()};
  # Note that even if there are no jobs to schedule
  # we should check if there are VMs to revert

  my %Hosts;
  my $VMs = CreateVMs($Jobs);
  $VMs->FilterEnabledRole();
  foreach my $VM (@{$VMs->GetItems()})
  {
    my $Host = $VM->GetHost();
    $Hosts{$Host}->{$VM->VirtURI} = 1;
  }

  my @ErrMessages;
  foreach my $Host (keys %Hosts)
  {
    my @HostHypervisors = keys %{$Hosts{$Host}};
    my $HostErrMessage = ScheduleOnHost($Jobs, \@SortedJobs, \@HostHypervisors);
    push @ErrMessages, $HostErrMessage if (defined $HostErrMessage);
  }
  return @ErrMessages ? join("\n", @ErrMessages) : undef;
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

sub FilterNotArchived($)
{
  my ($self) = @_;

  $self->AddFilter("Archived", [!1]);
}

1;

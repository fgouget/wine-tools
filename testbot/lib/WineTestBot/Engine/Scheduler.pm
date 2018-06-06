# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot engine scheduler
#
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

package WineTestBot::Engine::Scheduler;

=head1 NAME

WineTestBot::Engine::Scheduler - Schedules the TestBot tasks

=cut

use Exporter 'import';
our @EXPORT = qw(ScheduleJobs CheckJobs);

use WineTestBot::Config;
use WineTestBot::Engine::Events;
use WineTestBot::Jobs;
use WineTestBot::Log;
use WineTestBot::RecordGroups;
use WineTestBot::VMs;


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

sub _GetSchedHost($$)
{
  my ($Sched, $VM) = @_;

  my $HostKey = $VM->GetHost();
  if (!$Sched->{hosts}->{$HostKey})
  {
    $Sched->{hosts}->{$HostKey} = {
      queued => 0,  # Tasks
      active => 0,  # VMs...
      idle => 0,
      reverting => 0,
      sleeping => 0,
      running => 0,
      dirty => 0,
      dirtychild => 0,
      MaxRevertingVMs => $MaxRevertingVMs,
      MaxRevertsWhileRunningVMs => $MaxRevertsWhileRunningVMs,
      MaxActiveVMs => $MaxActiveVMs,
      MaxRunningVMs => $MaxRunningVMs,
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
  if ($VMKey eq $DomainVMKey)
  {
    # Already ours. Use it if it is not busy
    return !$VM->ChildPid;
  }

  # We cannot schedule anything on this VM if we cannot take the hypervisor
  # domain from its current owner. Note that we can always take over dirty VMs
  # if we did not start an operation on them yet (i.e. if they are in lambvms).
  if (!$Sched->{lambvms}->{$DomainVMKey} or
      (!$Steal and ($VM->Status eq "off" or $DomainVM->Status ne "dirty")))
  {
    return 0;
  }

  # $DomainVM is either dirty (with no child process), idle or sleeping.
  # Just mark it off and let the caller poweroff or revert the
  # hypervisor domain as needed for the new VM.
  $DomainVM->KillChild(); # For the sleeping case
  my $Host = _GetSchedHost($Sched, $DomainVM);
  $Host->{$DomainVM->Status}--;
  $Host->{active}--;
  $DomainVM->Status("off");
  $DomainVM->Save();
  # off VMs are neither in busyvms nor lambvms
  delete $Sched->{lambvms}->{$DomainVMKey};
  $Sched->{domains}->{$DomainKey} = $VM;
  return 1;
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
    blocked => 0,
    recordgroups => CreateRecordGroups(),
  };
  $Sched->{recordgroup} = $Sched->{recordgroups}->Add();
  $Sched->{records} = $Sched->{recordgroup}->Records;
  # Save the new RecordGroup now so its Id is lower than those of the groups
  # created by the scripts called from the scheduler.
  $Sched->{recordgroups}->Save();

  my $Now = time();
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
      if (defined $VM->ChildDeadline and $VM->ChildDeadline < $Now)
      {
        # The child process got stuck!
        $FoundVMErrors = 1;
        my $NewStatus = "dirty";
        if ($VM->Status eq "reverting" or $VM->Status eq "sleeping")
        {
          my $Errors = ($VM->Errors || 0) + 1;
          $VM->Errors($Errors);
          $NewStatus = "maintenance" if ($Errors >= $MaxVMErrors);
        }
        $VM->Status($NewStatus);
        $VM->KillChild();
        $VM->Save();
        $VM->RecordResult($Sched->{records}, "boterror stuck process");
        $Sched->{lambvms}->{$VMKey} = 1;
        $Host->{dirty}++;
        $Host->{active}++;
      }
      elsif ($VM->Status =~ /^(?:dirty|running|reverting)$/)
      {
        $Sched->{busyvms}->{$VMKey} = 1;
        $Host->{$VM->Status}++;
        $Host->{active}++;
        $Host->{dirtychild}++ if ($VM->Status eq "dirty");
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
        LogMsg "Unexpected $VMKey status ". $VM->Status ."\n";
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
        $VM->ChildDeadline(undef);
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
        if (_CanScheduleOnVM($Sched, $VM))
        {
          my $ErrMessage = $VM->RunMonitor();
          LogMsg "$ErrMessage\n" if (defined $ErrMessage);
        }
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
        LogMsg "Unexpected $VMKey status ". $VM->Status ."\n";
        $FoundVMErrors = 1;
        # Don't interfere with this VM
        $Sched->{busyvms}->{$VMKey} = 1;
      }
      # Note that off VMs are neither in busyvms nor lambvms
    }

    _CanScheduleOnVM($Sched, $VM);

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

  return $Sched;
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

    # The per-step lists of VMs that should be getting ready to run
    # before we prepare the next step
    my %StepVMs = ("" => []); # no dependency for the first step

    # Process the steps in increasing $Step->No order for the inter-step
    # dependencies
    my $Steps = $Job->Steps;
    $Steps->AddFilter("Status", ["queued", "running"]);
    foreach my $Step (sort { $a->No <=> $b->No } @{$Steps->GetItems()})
    {
      my $StepRank;
      my $Previous = "";  # Avoid undefined values for hash indices
      if (!$Step->PreviousNo)
      {
        # The first step may need to get files from the staging area
        $Step->HandleStaging() if ($Step->Status eq "queued");
        $StepRank = 0;
        $StepVMs{$Step} = [];
      }
      else
      {
        $Previous = $Steps->GetItem($Step->PreviousNo);
        if ($Previous->Status eq "completed")
        {
          # The previous step was successful so we can now run this one
          $StepRank = 0;
          $StepVMs{$Step} = [];
        }
        elsif ($StepVMs{$Previous})
        {
          # The previous step is almost done. Prepare this one.
          $StepRank = 1;
        }
        else
        {
          # The previous step is nowhere near done
          $StepRank = 2;
        }
      }

      my $Tasks = $Step->Tasks;
      $Tasks->AddFilter("Status", ["queued"]);
      foreach my $Task (@{$Tasks->GetItems()})
      {
        my $VM = $Task->VM;
        if (!$VM->HasEnabledRole() or !$VM->HasEnabledStatus())
        {
          $Sched->{blocked}++;
          next;
        }
        my $Host = _GetSchedHost($Sched, $VM);
        $Host->{queued}++;
        $Sched->{queued}++;

        if ($StepRank >= 2)
        {
          # The previous step is nowhere near done so skip this one for now
          next;
        }
        if ($StepRank == 1)
        {
          # Passing $StepVMs{$Previous} ensures this VM will be reverted
          # if and only if all of the previous step's tasks are about to run.
          # See _HasMissingDependencies().
          _AddNeededVM($NeededVMs, $VM, $NEXT_BASE + $JobRank,
                       $StepVMs{$Previous});
          next;
        }
        $Sched->{runnable}++; # $StepRank == 0

        if (!_AddNeededVM($NeededVMs, $VM, $JobRank))
        {
          # This VM is in $NeededVMs already which means it is already
          # scheduled to be reverted for a task with a higher priority.
          # So this task won't be run before a while and thus there is
          # no point in preparing the next step.
          $StepVMs{$Step} = undef;
          next;
        }

        # It's not worth preparing the next step for tasks that take so long
        $StepVMs{$Step} = undef if ($Task->Timeout > $BuildTimeout);

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

          # Dirty VMs are VMs that were running and have still not been
          # powered off. Sleeping VMs may be VMs that are booting.
          # So in both cases they may still be using CPU and I/O resources so
          # count them against the running VM limit.
          if ($Host->{sleeping} + $Host->{running} + $Host->{dirty} < $Host->{MaxRunningVMs} and
              ($Host->{reverting} == 0 or
               $Host->{reverting} <= $Host->{MaxRevertsWhileRunningVMs}) and
              _CanScheduleOnVM($Sched, $VM))
          {
            $Sched->{busyvms}->{$VMKey} = 1;
            $VM->RecordStatus($Sched->{records}, join(" ", "running", $Job->Id, $Step->No, $Task->No));
            my $ErrMessage = $Task->Run($Step);
            LogMsg "$ErrMessage\n" if (defined $ErrMessage);

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
          $StepVMs{$Step} = undef;
        }
        push @{$StepVMs{$Step}}, $VM if ($StepVMs{$Step});
      }
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

  return $NeededVMs;
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

sub _DumpHostCounters($$)
{
  my ($Sched, $VM) = @_;
  my $Host = _GetSchedHost($Sched, $VM);
  return if ($Host->{dumpedcounters});

  my $Counters = "";
  if ($Host->{active})
  {
    $Counters .= " active=$Host->{active}/$Host->{MaxActiveVMs}";
  }
  if ($Host->{idle})
  {
    $Counters .= " idle=$Host->{idle}". ($Host->{queued} ? "" : "/$Host->{MaxVMsWhenIdle}");
  }
  if ($Host->{reverting})
  {
    $Counters .= " reverting=$Host->{reverting}/". _GetMaxReverts($Host);
  }
  for my $Counter ("sleeping", "running", "dirty", "queued")
  {
    $Counters .= " $Counter=$Host->{$Counter}" if ($Host->{$Counter});
  }
  my $HostKey = $VM->GetHost();
  my $PrettyHost = ($PrettyHostNames ? $PrettyHostNames->{$HostKey} : "") ||
                   $HostKey;
  LogMsg "$PrettyHost:$Counters\n" if ($Counters);

  $Host->{dumpedcounters} = 1;
}

sub _DumpHostVMs($$$$)
{
  my ($Sched, $VM, $SortedNeededVMs, $NeededVMs) = @_;
  my $Host = _GetSchedHost($Sched, $VM);
  return if ($Host->{dumpedvms});

  _DumpHostCounters($Sched, $VM);

  my @VMInfo;
  my $HostKey = $VM->GetHost();
  foreach my $VMKey (@$SortedNeededVMs)
  {
    $VM = $Sched->{VMs}->GetItem($VMKey);
    next if ($VM->GetHost() ne $HostKey);

    my $NeededVM = $NeededVMs->{$VMKey};
    my $Dep = "";
    if ($NeededVM->[3])
    {
      foreach my $DepVM (@{$NeededVM->[3]})
      {
        if ($DepVM->Status !~ /^(?:reverting|sleeping|running)$/)
        {
          $Dep = ":". $DepVM->Name;
          last;
        }
      }
      $Dep .= "/". scalar(@{$NeededVM->[3]});
    }
    push @VMInfo, join(":", "$VMKey(". $VM->Status ."$Dep)",
                       $NeededVM->[0], $NeededVM->[1], $NeededVM->[2]);
  }
  my $PrettyHost = ($PrettyHostNames ? $PrettyHostNames->{$HostKey} : "") ||
                   $HostKey;
  LogMsg "$PrettyHost: @VMInfo\n";

  $Host->{dumpedvms} = 1;
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
    _DumpHostCounters($Sched, $VM);

    # Skip this VM if the previous step's tasks are not about to run yet
    next if (_HasMissingDependencies($Sched, $NeededVMs, $VMKey));

    # Don't steal the hypervisor domain for a VM we will only need later
    my $Steal = (_GetNiceness($NeededVMs, $VMKey) < $NEXT_BASE);
    next if (!_CanScheduleOnVM($Sched, $VM, $Steal));

    my $NeedsSacrifice;
    if (_GetNiceness($NeededVMs, $VMKey) >= $FUTURE_BASE)
    {
      # Only start preparing VMs for future jobs on a host which is idle, i.e.
      # which no longer has queued tasks (ignoring blocked ones).
      # Note that during regular operation we get dirty VMs before they are
      # assigned a process to shut them down. This makes it possible to pick
      # the best future VM while we still know which VM is hot.
      # In constrast on startup the dirty VMs all have processes checking their
      # status, hence the dirtychild check to ensure we are not prevented from
      # preparing the best VM (e.g. build): it delays preparing the future VMs
      # until either there are no dirty VM or a VM got prepared for a task
      # which means the host is not idle.
      if ($Host->{queued} != 0 or $Host->{MaxVMsWhenIdle} == 0 or
          ($Host->{active} and $Host->{active} == $Host->{dirtychild}))
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

    _DumpHostVMs($Sched, $VM, \@SortedNeededVMs, $NeededVMs);
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
      LogMsg "$ErrMessage\n" if (defined $ErrMessage);
      $Host->{active}++ if ($VMStatus eq "off");
      $Host->{reverting}++;
    }
  }
}

sub _PowerOffDirtyVMs($)
{
  my ($Sched) = @_;

  # Power off any still dirty VM
  foreach my $VMKey (keys %{$Sched->{lambvms}})
  {
    my $VM = $Sched->{VMs}->GetItem($VMKey);
    next if ($VM->Status ne "dirty");
    next if (!_CanScheduleOnVM($Sched, $VM));

    $VM->RecordStatus($Sched->{records}, "dirty poweroff");
    my $ErrMessage = $VM->RunPowerOff();
    LogMsg "$ErrMessage\n" if (defined $ErrMessage);
  }
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
  my $Sched = _CheckAndClassifyVMs();
  my $NeededVMs = _ScheduleTasks($Sched);
  _RevertVMs($Sched, $NeededVMs);
  _PowerOffDirtyVMs($Sched);

  # Note that any VM Status or Role change will trigger ScheduleJobs() so this
  # records all not yet recorded VM state changes, even those not initiated by
  # the scheduler.
  map { $_->RecordStatus($Sched->{records}) } @{$Sched->{VMs}->GetItems()};

  if (@{$Sched->{records}->GetItems()})
  {
    my $TaskCounts = "$Sched->{runnable} $Sched->{queued} $Sched->{blocked}";
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

  # Reschedule at the latest when the next task times out
  my $FirstDeadline;
  foreach my $VM (@{$Sched->{VMs}->GetItems()})
  {
    if (defined $VM->ChildDeadline and
        (!defined $FirstDeadline or $VM->ChildDeadline < $FirstDeadline))
    {
      $FirstDeadline = $VM->ChildDeadline;
    }
  }
  my $Timeout;
  if ($FirstDeadline)
  {
    $Timeout = $FirstDeadline - time();
    $Timeout = 1 if ($Timeout <= 0);
  }
  if (!$Timeout or $Timeout > 600)
  {
    # Reschedule regularly as a safety net
    $Timeout = 600;
  }
  AddEvent("ScheduleJobs", $Timeout, 0, \&ScheduleJobs);
}


1;

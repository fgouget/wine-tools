#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# The WineTestBot server, aka the engine that makes it all work.
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

use Errno qw(EAGAIN);
use Fcntl;
use MIME::Parser;
use POSIX ":sys_wait_h";
use Socket;
use File::Path;

use ObjectModel::BackEnd;

use WineTestBot::Config;
use WineTestBot::Engine::Events;
use WineTestBot::Engine::Notify;
use WineTestBot::Jobs;
use WineTestBot::Log;
use WineTestBot::Patches;
use WineTestBot::PendingPatchSets;
use WineTestBot::RecordGroups;
use WineTestBot::Utils;
use WineTestBot::VMs;

my $RunEngine = 1;

sub FatalError(@)
{
  LogMsg @_;
  LogMsg "Shutdown following a fatal error\n";

  exit 1;
}


=pod
=over 12

=item C<Cleanup()>

The Cleanup() function gets the Tasks and VMs in a consistent state on the
Engine startup or cleanly stops the Tasks and VMs on shutdown.
It has to contend with three main scenarios:
- The Engine being restarted. Any task started just before that is still
  running should still have its process and powered on VM and should be left
  alone so it can complete normally. If a task died unexpectedly while the
  Engine was down it's ok to requeue it.
- The Engine startup after a reboot. All task processes will be dead and need
  to be requeued. But the VMs are likely to be hosted on a separate machine so
  it is quite possible that they will still be running. Hopefully any running
  process matching a VM's ChildPid will belong to another user so we don't
  mistake that case for the previous one.
- A shutdown of the Engine and its Tasks / VMs. In this case Cleanup() is used
  to kill the running tasks and requeue them, and/or power off the VMs.

In all cases the VM status field cannot be trusted blindly.
If the VM status indicates it can have a running process and it actually has
a running process then we will trust the VM status.
If the VM status is 'idle' we let RunCheckIdle() perform the relevant domain
checks and update the status as appropriate.
In all other cases the VM is powered off and marked as such.

=back
=cut

sub Cleanup($;$$)
{
  my ($Starting, $KillTasks, $KillVMs) = @_;

  # Verify that the running tasks are still alive and requeue them if not.
  # Ignore the Job and Step status fields because they may be a bit out of date.
  my %RunningVMs;
  foreach my $Job (@{CreateJobs()->GetItems()})
  {
    my $CallUpdateStatus;
    foreach my $Step (@{$Job->Steps->GetItems()})
    {
      my $Tasks = $Step->Tasks;
      $Tasks->AddFilter("Status", ["running"]);
      foreach my $Task (@{$Tasks->GetItems()})
      {
        my $TaskKey = join("/", $Job->Id, $Step->No, $Task->No);
        my $VM = $Task->VM;

        my $Requeue;
        if (!$VM->HasRunningChild())
        {
          # That task's process died somehow.
          $Requeue = 1;
        }
        elsif ($VM->Status ne "running")
        {
          # The Task and VM status should match.
          $Requeue = 1;
        }
        elsif ($KillTasks)
        {
          # We will kill the child process so requeue the Task.
          $Requeue = 1;
        }
        else
        {
          # This task is still running!
          LogMsg "$TaskKey is still running\n";
          $RunningVMs{$Task->VM->GetKey()} = join(" ", "running", $Job->Id, $Step->No, $Task->No);
          next;
        }
        if ($Requeue)
        {
          LogMsg "Requeuing $TaskKey\n";
          $Task->RmTree();
          $Task->Status("queued");
          $Task->Started(undef);
          $Task->Ended(undef);
          $Task->TestFailures(undef);
          $Task->Save();
          $CallUpdateStatus = 1;
        }
      }
    }
    # The Job and Steps status fields will actually remain unchanged except if
    # the task that died was in the first step. In that case they will revert
    # from 'running' to 'queued'.
    $Job->UpdateStatus() if ($CallUpdateStatus);
  }

  # Get the VMs in order now
  my $RecordGroups = CreateRecordGroups();
  my $Records = $RecordGroups->Add()->Records;
  # Save the new RecordGroup now so its Id is lower than those of the groups
  # created by the scripts called from Cleanup().
  $RecordGroups->Save();

  my $VMs = CreateVMs();
  foreach my $VM (@{$VMs->GetItems()})
  {
    my $VMKey = $VM->GetKey();
    if (!$VM->HasEnabledRole() or !$VM->HasEnabledStatus())
    {
      $VM->RecordStatus($Records);
      next;
    }

    if ($RunningVMs{$VMKey})
    {
      # This VM is still running a task. Let it.
      LogMsg "$VMKey is $RunningVMs{$VMKey}\n";
      $VM->RecordStatus($Records, $RunningVMs{$VMKey});
      next;
    }

    if ($VM->HasRunningChild())
    {
      if ($KillTasks and $VM->Status eq "running")
      {
        $VM->KillChild();
        $VM->RunPowerOff();
        $VM->RecordStatus($Records, "dirty poweroff (kill tasks)");
      }
      elsif ($KillVMs and $VM->Status ne "running")
      {
        $VM->KillChild();
        # $KillVMs is normally used on shutdown so don't start a process that
        # will get stuck 'forever' waiting for an offline VM.
        if ($VM->Status ne "offline")
        {
          $VM->RunPowerOff();
          $VM->RecordStatus($Records, "dirty poweroff (kill vms)");
        }
      }
      elsif (!$VM->CanHaveChild())
      {
        # The VM should not have a process.
        $VM->KillChild();
        $VM->RunCheckOff();
        $VM->RecordStatus($Records, "dirty off check (unexpected process)");
      }
      elsif ($Starting)
      {
        # Let the process finish its work. Note that on shutdown we don't
        # record the VM status if it did not change.
        $VM->RecordStatus($Records);
      }
    }
    elsif ($Starting)
    {
      if ($VM->Status eq "idle")
      {
        $VM->RunCheckIdle();
        $VM->RecordStatus($Records, "dirty idle check");
      }
      else
      {
        # Power off the VM, even if its status is already off.
        # This is the simplest way to resync the VM status field.
        # Also powering off a powered off VM will detect offline VMs.
        $VM->RunCheckOff();
        $VM->RecordStatus($Records, "dirty off check");
      }
    }
    # $KillVMs is normally used on shutdown so don't start a process that
    # will get stuck 'forever' waiting for an offline VM.
    elsif ($KillVMs and $VM->Status !~ /^(?:off|offline)$/)
    {
      $VM->RunPowerOff();
      $VM->RecordStatus($Records, "dirty poweroff (kill vms)");
    }
    # Note that on shutdown we don't record the VM status if it did not change.
  }
  $RecordGroups->Save();
}


sub HandleShutdown($$)
{
  my ($KillTasks, $KillVMs) = @_;

  if (!defined $KillTasks or !defined $KillVMs)
  {
    LogMsg "Missing parameters in shutdown message\n";
    return "0Missing shutdown parameters";
  }

  # Untaint parameters
  if ($KillTasks =~ /^([01])$/)
  {
    $KillTasks = $1;
  }
  else
  {
    LogMsg "Invalid KillTasks $KillTasks in shutdown message\n";
    return "0Invalid KillTasks shutdown parameter\n";
  }
  if ($KillVMs =~ /^([01])$/)
  {
    $KillVMs = $1;
  }
  else
  {
    LogMsg "Invalid KillVMs $KillVMs in shutdown message\n";
    return "0Invalid KillVMs shutdown parameter\n";
  }

  Cleanup(0, $KillTasks, $KillVMs);
  $RunEngine = 0;

  LogMsg "Waiting for the last clients to disconnect...\n";
  return "1OK\n";
}

sub HandlePing()
{
  return "1pong\n";
}

sub HandleJobStatusChange($$$)
{
  my ($JobKey, $OldStatus, $NewStatus) = @_;

  if (! defined($OldStatus) || ! defined($NewStatus))
  {
    LogMsg "Invalid status in jobstatuschange message\n";
    return "0Invalid status";
  }

  # Untaint parameters
  if ($JobKey =~ /^(\d+)$/)
  {
    $JobKey = $1;
  }
  else
  {
    LogMsg "Invalid JobKey $JobKey in jobstatuschange message\n";
  }

  if ($OldStatus eq "running" && $NewStatus ne "running")
  {
    my $Pid = fork;
    if (!defined $Pid)
    {
      LogMsg "Unable to fork for ${ProjectName}SendLog.pl: $!\n";
    }
    elsif (!$Pid)
    {
      # Clean up the child environment
      CloseAllDBBackEnds();
      WineTestBot::Log::SetupRedirects();

      exec("$BinDir/${ProjectName}SendLog.pl $JobKey") or
      LogMsg "Unable to exec ${ProjectName}SendLog.pl: $!\n";
      exit(1);
    }
  }

  return "1OK";
}

sub HandleJobCancel($)
{
  my ($JobKey) = @_;

  my $Job = CreateJobs()->GetItem($JobKey);
  if (! $Job)
  {
    LogMsg "JobCancel for nonexistent job $JobKey\n";
    return "0Job $JobKey not found";
  }
  # We've already determined that JobKey is valid, untaint it
  $JobKey =~ m/^(.*)$/;
  $JobKey = $1;

  my $ErrMessage = $Job->Cancel();
  if (defined($ErrMessage))
  {
    LogMsg "Cancel problem: $ErrMessage\n";
    return "0$ErrMessage";
  }

  $ErrMessage = ScheduleJobs();
  if (defined($ErrMessage))
  {
    LogMsg "Scheduling problem in HandleJobCancel: $ErrMessage\n";
  }

  return "1OK";
}

sub HandleJobRestart($)
{
  my ($JobKey) = @_;

  my $Job = CreateJobs()->GetItem($JobKey);
  if (! $Job)
  {
    LogMsg "JobRestart for nonexistent job $JobKey\n";
    return "0Job $JobKey not found";
  }
  # We've already determined that JobKey is valid, untaint it
  $JobKey =~ m/^(.*)$/;
  $JobKey = $1;

  my $ErrMessage = $Job->Restart();
  if (defined($ErrMessage))
  {
    LogMsg "Restart problem: $ErrMessage\n";
    return "0$ErrMessage";
  }

  $ErrMessage = ScheduleJobs();
  if (defined($ErrMessage))
  {
    LogMsg "Scheduling problem in HandleJobRestart: $ErrMessage\n";
  }

  return "1OK";
}

sub HandleRescheduleJobs()
{
  my $ErrMessage = ScheduleJobs();
  if (defined($ErrMessage))
  {
    LogMsg "Scheduling problem in HandleRescheduleJobs: $ErrMessage\n";
  }

  return "1OK";
}

sub HandleVMStatusChange($$$)
{
  my ($VMKey, $OldStatus, $NewStatus) = @_;

  if (! defined($OldStatus) || ! defined($NewStatus))
  {
    LogMsg "Invalid status in vmstatuschange message\n";
    return "0Invalid status";
  }

  my $ErrMessage = ScheduleJobs();
  if (defined($ErrMessage))
  {
    LogMsg "Scheduling problem in HandleVMStatusChange: $ErrMessage\n";
    return "0$ErrMessage";
  }

  return "1OK";
}

sub HandleWinePatchMLSubmission()
{
  my $dh;
  if (!opendir($dh, "$DataDir/staging"))
  {
    return "0Unable to open '$DataDir/staging': $!";
  }

  # Read the directory ahead as we'll be adding / removing entries
  my @Entries = readdir($dh);
  closedir($dh);

  my @ErrMessages;
  foreach my $Entry (@Entries)
  {
    # Validate file name
    next if ($Entry !~ m/^([0-9a-fA-F]{32}_wine-patches)$/);
    my $FullMessageFileName = "$DataDir/staging/$1";

    # Create a work directory
    my $WorkDir = CreateNewDir("$DataDir/staging", "_work");

    # Process the patch
    my $Parser = new MIME::Parser;
    $Parser->output_dir($WorkDir);
    my $Entity = $Parser->parse_open($FullMessageFileName);
    my $ErrMessage = CreatePatches()->NewPatch($Entity);
    push @ErrMessages, $ErrMessage if (defined $ErrMessage);

    # Clean up
    if (!rmtree($WorkDir))
    {
       # Not a fatal error but log it to help diagnosis
       LogMsg "Unable to delete '$WorkDir': $!\n";
    }
    if (!unlink($FullMessageFileName))
    {
      # This is more serious because it could cause a patch to be added
      # again and again. But there is not much we can do.
      LogMsg "Unable to delete '$FullMessageFileName': $!\n";
    }
  }

  return @ErrMessages ? "0". join("; ", @ErrMessages) : "1OK";
}

sub HandleWinePatchWebSubmission()
{
  my $LatestWebPatchId = 0;
  my $Patches = CreatePatches();
  foreach my $Patch (@{$Patches->GetItems()})
  {
    my $WebPatchId = $Patch->WebPatchId;
    if (defined $WebPatchId and $LatestWebPatchId < $WebPatchId)
    {
      $LatestWebPatchId = $WebPatchId;
    }
  }

  # Rescan the directory for robustness in case the patches site has already
  # expired $LatestWebPatchId+1 (for instance if the WineTestBot has not been
  # run for a while).
  my (@ErrMessages, @WebPatchIds);
  if (opendir(my $dh, "$DataDir/webpatches"))
  {
    foreach my $Entry (readdir($dh))
    {
      next if ($Entry !~ /^(\d+)$/);
      my $WebPatchId = $1;
      next if ($WebPatchId <= $LatestWebPatchId);

      my $Patches = CreatePatches($Patches);
      $Patches->AddFilter("WebPatchId", [$WebPatchId]);
      if (@{$Patches->GetKeys()})
      {
        push @ErrMessages, "$WebPatchId already exists and yet the latest patch is $LatestWebPatchId";
        next;
      }
      push @WebPatchIds, $WebPatchId;
    }
    close($dh);
  }
  else
  {
    return "0Unable to open '$DataDir/webpatches': $!";
  }

  # Add the patches in increasing WebPatchId order so that next time
  # $LatestWebPatchId still makes sense in case something goes wrong now
  foreach my $WebPatchId (sort { $a <=> $b } @WebPatchIds)
  {
    # Create a working dir
    my $WorkDir = CreateNewDir("$DataDir/staging", "_work");

    # Process the patch
    my $Parser = new MIME::Parser;
    $Parser->output_dir($WorkDir);
    my $Entity = $Parser->parse_open("$DataDir/webpatches/$WebPatchId");
    my $ErrMessage = $Patches->NewPatch($Entity, $WebPatchId);
    push @ErrMessages, $ErrMessage if (defined $ErrMessage);

    # Clean up
    if (!rmtree($WorkDir))
    {
      # Not a fatal error but log it to help diagnosis
      LogMsg "Unable to delete '$WorkDir': $!\n";
    }
  }

  return @ErrMessages ? "0". join("; ", @ErrMessages) : "1OK";
}

sub HandleGetScreenshot($)
{
  my ($VMName) = @_;

  # Validate VM name
  if ($VMName !~ m/^(\w+)$/)
  {
    LogMsg "Invalid VM name for screenshot\n";
    return "0Invalid VM name";
  }
  $VMName = $1;

  my $VM = CreateVMs()->GetItem($VMName);
  if (! defined($VM))
  {
    LogMsg "Unknown VM $VMName for screenshot\n";
    return "0Unknown VM $VMName";
  }

  # FIXME: Taking a screenshot leaks libvirt connections, takes a long time and
  # blocks the Engine during the whole operation. So live screenshots are
  # disabled for now.
  my ($ErrMessage, $ImageSize, $ImageBytes) = ("Screenshotting has been disabled for the time being", undef, undef); #$VM->GetDomain()->CaptureScreenImage();
  if (defined($ErrMessage))
  {
    LogMsg "Failed to take screenshot of $VMName: $ErrMessage\n";
    return "0$ErrMessage";
  }

  return "1" . $ImageBytes;
}

my %Handlers=(
    "getscreenshot"            => \&HandleGetScreenshot,
    "jobcancel"                => \&HandleJobCancel,
    "jobrestart"               => \&HandleJobRestart,
    "jobstatuschange"          => \&HandleJobStatusChange,
    "ping"                     => \&HandlePing,
    "shutdown"                 => \&HandleShutdown,
    "reschedulejobs"           => \&HandleRescheduleJobs,
    "vmstatuschange"           => \&HandleVMStatusChange,
    "winepatchmlsubmission"    => \&HandleWinePatchMLSubmission,
    "winepatchwebsubmission"   => \&HandleWinePatchWebSubmission,
    );

sub HandleClientCmd(@)
{
  my $Cmd = shift;

  my $handler = $Handlers{$Cmd};
  return &$handler(@_) if (defined $handler);

  LogMsg "Unknown command $Cmd\n";
  return "0Unknown command $Cmd\n";
}

sub ClientRead($)
{
  my ($Client) = @_;

  my $Buf;
  my $GotSomething = !1;
  while (my $Len = sysread($Client->{Socket}, $Buf, 128))
  {
    $Client->{InBuf} .= $Buf;
    $GotSomething = 1;
  }

  return $GotSomething;
}

=pod
=over 12

=item C<SafetyNet()>

This is called on startup and regularly after that to catch things that fall
through the cracks, possibly because of an Engine restart.
Specifically it updates the status of all the current Jobs, Steps and
Tasks, then schedules Tasks to be run, checks the staging directory for
wine-patches emails dropped by WinePatchesMLSubmit.pl, for notifications of
changes on Wine's Patches web site dropped by WinePatchesWebSubmit.pl, and
checks whether any pending patchsets are now complete and thus can be scheduled.

=back
=cut

sub SafetyNet()
{
  CheckJobs();
  ScheduleJobs();
  HandleWinePatchWebSubmission();

  my $Set = WineTestBot::PendingPatchSets::CreatePendingPatchSets();
  my $ErrMessage = $Set->CheckForCompleteSet();
  if (defined($ErrMessage))
  {
    LogMsg "Failed to check completeness of patch series: $ErrMessage\n";
  }
}

sub PrepareSocket($)
{
  my ($Socket) = @_;

  my $Flags = 0;
  if (fcntl($Socket, F_GETFL, $Flags))
  {
    $Flags |= O_NONBLOCK;
    if (! fcntl($Socket, F_SETFL, $Flags))
    {
      LogMsg "Unable to make socket non-blocking during set: $!";
      return !1;
    }
  }
  else
  {
    LogMsg "Unable to make socket non-blocking during get: $!";
    return !1;
  }

  if (fcntl($Socket, F_GETFD, $Flags))
  {
    $Flags |= FD_CLOEXEC;
    if (! fcntl($Socket, F_SETFD, $Flags))
    {
      LogMsg "Unable to make socket close-on-exit during set: $!";
      return !1;
    }
  }
  else
  {
    LogMsg "Unable to make socket close-on-exit during get: $!";
    return !1;
  }


  return 1;
}

sub REAPER
{
  my $Child;
  # If a second child dies while in the signal handler caused by the
  # first death, we won't get another signal. So must loop here else
  # we will leave the unreaped child as a zombie. And the next time
  # two children die we get another zombie. And so on.
  while (0 < ($Child = waitpid(-1, WNOHANG)))
  {
    ;
  }
  $SIG{CHLD} = \&REAPER; # still loathe SysV
}

sub main()
{
  my ($Shutdown, $KillTasks, $KillVMs);
  while (@ARGV)
  {
    my $Arg = shift @ARGV;
    if ($Arg eq "--shutdown")
    {
      $Shutdown = 1;
    }
    elsif ($Arg eq "--kill-tasks")
    {
      $KillTasks = 1;
      $Shutdown = 1;
    }
    elsif ($Arg eq "--kill-vms")
    {
      $KillVMs = 1;
      $Shutdown = 1;
    }
    else
    {
      die "Usage: Engine.pl [--shutdown] [--kill-tasks] [--kill-vms]";
    }
  }
  if ($Shutdown)
  {
    my $ErrMessage = Shutdown($KillTasks, $KillVMs);
    if (defined $ErrMessage)
    {
      print STDERR "$ErrMessage\n";
      exit 1;
    }
    exit 0;
  }
  if (PingEngine())
  {
    print STDERR "The WineTestBot Engine is running already\n";
    exit 1;
  }

  $ENV{PATH} = "/usr/bin:/bin";
  delete $ENV{ENV};
  $SIG{CHLD} = \&REAPER;

  $WineTestBot::Engine::Notify::RunningInEngine = 1;
  LogMsg "Starting the WineTestBot Engine\n";

  # Validate and adjust the configuration options
  $MaxActiveVMs ||= 1;
  $MaxRunningVMs ||= $MaxActiveVMs;
  if ($MaxRunningVMs > $MaxActiveVMs)
  {
    $MaxRunningVMs = $MaxActiveVMs;
    LogMsg "Capping MaxRunningVMs to MaxActiveVMs ($MaxRunningVMs)\n";
  }
  $MaxRevertingVMs ||= $MaxActiveVMs;
  if ($MaxRevertingVMs > $MaxActiveVMs)
  {
    $MaxRevertingVMs = $MaxActiveVMs;
    LogMsg "Capping MaxRevertingVMs to MaxActiveVMs ($MaxRevertingVMs)\n";
  }
  $MaxRevertsWhileRunningVMs ||= 0;
  if ($MaxRevertsWhileRunningVMs > $MaxRevertingVMs)
  {
    $MaxRevertsWhileRunningVMs = $MaxRevertingVMs;
    LogMsg "Capping MaxRevertsWhileRunningVMs to MaxRevertingVMs ($MaxRevertsWhileRunningVMs)\n";
  }
  $MaxVMsWhenIdle = $MaxActiveVMs if (!defined $MaxVMsWhenIdle);
  SaveRecord('engine', 'start');
  Cleanup(1);

  # Check for patches that arrived while the server was off.
  HandleWinePatchMLSubmission();

  my $SockName = "$DataDir/socket/engine";
  my $uaddr = sockaddr_un($SockName);
  my $proto = getprotobyname('tcp');

  my $Sock;
  my $paddr;

  unlink($SockName);
  if (! socket($Sock,PF_UNIX,SOCK_STREAM,0))
  {
    FatalError "Unable to create socket: $!\n";
  }
  if (! bind($Sock, $uaddr))
  {
    FatalError "Unable to bind socket: $!\n";
  }
  chmod 0777, $SockName;
  if (! listen($Sock, SOMAXCONN))
  {
    FatalError "Unable to listen on socket: $!\n";
  }
  PrepareSocket($Sock);

  SafetyNet();
  AddEvent("SafetyNet", 600, 1, \&SafetyNet);

  my @Clients;
  while ($RunEngine or @Clients)
  {
    my $ReadyRead = "";
    my $ReadyWrite = "";
    my $ReadyExcept = "";
    vec($ReadyRead, fileno($Sock), 1) = 1;
    foreach my $Client (@Clients)
    {
      vec($ReadyRead, fileno($Client->{Socket}), 1) = 1;
      if ($Client->{OutBuf} ne "")
      {
        vec($ReadyWrite, fileno($Client->{Socket}), 1) = 1;
      }
      vec($ReadyExcept, fileno($Client->{Socket}), 1) = 1;
    }

    my $Timeout = RunEvents();
    my $NumFound = select($ReadyRead, $ReadyWrite, $ReadyExcept, $Timeout);
    if (vec($ReadyRead, fileno($Sock), 1))
    {
      my $NewClientSocket;
      if (accept($NewClientSocket, $Sock))
      {
        if (PrepareSocket($NewClientSocket))
        {
          push @Clients, {Socket => $NewClientSocket,
                          InBuf => "",
                          OutBuf => ""};
        }
        else
        {
          close($NewClientSocket);
        }
      }
      elsif ($! != EAGAIN)
      {
        LogMsg "Socket accept failed: $!\n";
      }
    }

    my $ClientIndex = 0;
    foreach my $Client (@Clients)
    {
      my $Client = $Clients[$ClientIndex];
      my $NeedClose = !1;
      if (vec($ReadyRead, fileno($Client->{Socket}), 1))
      {
        $NeedClose = ! ClientRead($Client);

        if (0 < length($Client->{InBuf}) &&
            substr($Client->{InBuf}, length($Client->{InBuf}) - 1, 1) eq "\n")
        {
          $Client->{OutBuf} = HandleClientCmd(split ' ', $Client->{InBuf});
          $Client->{InBuf} = "";
        }
      }
      if (vec($ReadyWrite, fileno($Client->{Socket}), 1))
      {
        my $Len = syswrite($Client->{Socket}, $Client->{OutBuf},
                  length($Client->{OutBuf}));
        if (! defined($Len))
        {
          LogMsg "Error writing reply to client: $!\n";
          $NeedClose = 1;
        }
        else
        {
          $Client->{OutBuf} = substr($Client->{OutBuf}, $Len);
          if ($Client->{OutBuf} eq "")
          {
            $NeedClose = 1;
          }
        }
      }
      if (vec($ReadyExcept, fileno($Client->{Socket}), 1))
      {
        LogMsg "Except condition on client connection\n";
        $NeedClose = 1;
      }
      if ($NeedClose)
      {
        close $Client->{Socket};
        splice(@Clients, $ClientIndex, 1);
      }
      else
      {
        $ClientIndex++;
      }
    }
  }
  SaveRecord('engine', 'stop');

  LogMsg "Normal WineTestBot Engine shutdown\n";
  return 0;
}

exit main();

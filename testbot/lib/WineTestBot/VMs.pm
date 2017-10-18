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

package WineTestBot::VM;

=head1 NAME

WineTestBot::VM - A VM instance

=head1 DESCRIPTION

A VM defines the environment a test will be run on, that is, typically, a
specific virtual machine snapshot.

This class provides access to the properties identifying this environment, its
intended use and current state.

The GetDomain() method returns an object that can be used to start, stop, or
get the status of the VM, as well as manipulate its snapshots.

And the GetAgent() method returns a TestAgent instance configured for that VM.
This object can be used to copy files to or from the VM and to run commands in
it. This part is used to start the tasks in the VM but is implemented
independently from the VM's hypervisor since most do not provide this
functionality.

The VM type defines what it can do:

=over 12

=item build

This is a Unix VM that can build the 32-bit and 64-bit Windows test binaries.

=item win32

This is a 32-bit Windows VM that can run the 32-bit tests.

=item win64

This is a 64-bit Windows VM that can run both the 32-bit and 64-bit tests.

=back


The VM role defines what we use it for:

=over 12

=item retired

A retired VM is no longer used at all. No new jobs can be scheduled to run on
them.

=item base

A base VM is used for every suitable task. This is the only role that build VMs
can play besides retired. For Windows VMs, this means that it will run the
WineTest jobs, the wine-patches jobs, and also the manually submitted jobs
unless the submitter decided otherwise.

=item winetest

This is only valid for Windows VMs. By default these VMs only run the WineTest
jobs. They can also be selected for manually submitted jobs.

=item extra

This is only valid for Windows VMs. They are only used if selected for a
manually submitted job.

=back


A VM typically goes through the following states in this order:

=over 12

=item reverting

The VM is currently being reverted to the idle snapshot. Note that the idle
snapshot is supposed to be taken on a powered on VM so this also powers on the
VM.

=item sleeping

The VM has been reverted to the idle snapshot and we are now letting it settle
down for $SleepAfterRevert seconds (for instance so it gets time to renew its
DHCP leases). It is not running a task yet.

=item idle

The VM powered on and is no longer in its sleeping phase. So it is ready to be
given a task.

=item running

The VM is running some task.

=item dirty

The VM has completed the task it was given and must now be reverted to a clean
state before it can be used again. If it is not needed right away it may be
powered off instead.

=item off

The VM is not currently needed and has been powered off to free resources for
the other VMs.

=item offline

An error occurred with this VM (typically it failed to revert or is not
responding anymore), making it temporarily unusable. New jobs can still be
added for this VM but they won't be run until an administrator fixes it.
The main web status page has a warning indicator on when some VMs are offline.

=item maintenance

A WineTestBot administrator is working on the VM so that it cannot be used for
the tests. The main web status page has a warning indicator on when some VMs
are undergoing maintenance.

=back

=cut

use File::Basename;

use ObjectModel::BackEnd;
use WineTestBot::Config;
use WineTestBot::Engine::Notify;
use WineTestBot::LibvirtDomain;
use WineTestBot::TestAgent;
use WineTestBot::WineTestBotObjects;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub _initialize($$)
{
  my ($self, $VMs) = @_;

  $self->SUPER::_initialize($VMs);

  $self->{OldStatus} = undef;
}

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->Status("idle");
  $self->IdleSnapshot("wtb");

  $self->SUPER::InitializeNew($Collection);
}

sub GetHost($)
{
  my ($self) = @_;

  # The URI is of the form protocol://user@hostname/hypervisor-specific-data
  return $1 if ($self->VirtURI =~ m%^[^:]+://(?:[^/@]*@)?([^/]+)/%);
  return "localhost";
}

sub GetDomain($)
{
  my ($self) = @_;

  return LibvirtDomain->new($self);
}

sub GetAgent($)
{
  my ($self) = @_;

  # Use either the tunnel specified in the configuration file
  # or autodetect the settings based on the VM's VirtURI setting.
  my $URI = $Tunnel || $self->VirtURI;

  my $TunnelInfo;
  if ($URI =~ s/^(?:[a-z]+\+)?(?:ssh|libssh2):/ssh:/)
  {
    require URI;
    my $ParsedURI = URI->new($URI);
    %$TunnelInfo = %$TunnelDefaults if ($TunnelDefaults);
    $TunnelInfo->{sshhost}  = $ParsedURI->host;
    $TunnelInfo->{sshport}  = $ParsedURI->port;
    $TunnelInfo->{username} = $ParsedURI->userinfo;
  }
  return TestAgent->new($self->Hostname, $AgentPort, $TunnelInfo);
}

sub Status($;$)
{
  my ($self, $NewStatus) = @_;

  my $CurrentStatus = $self->SUPER::Status;
  return $CurrentStatus if (!defined $NewStatus);

  if ($NewStatus ne $CurrentStatus)
  {
    $self->SUPER::Status($NewStatus);
    $self->{OldStatus} = $CurrentStatus;
  }

  return $NewStatus;
}

=pod
=over 12

=item C<CanHaveChild()>

Returns true if the VM status is compatible with ChildPid being set.

=back
=cut

sub CanHaveChild($)
{
  my ($self) = @_;
  return ($self->Status =~ /^(?:dirty|reverting|sleeping)$/);
}

=pod
=over 12

=item C<HasRunningChild()>

Returns true if ChildPid is set and still identifies a running process.

=back
=cut

sub HasRunningChild($)
{
  my ($self) = @_;
  return undef if (!$self->ChildPid);
  return kill(0, $self->ChildPid);
}

=pod
=over 12

=item C<KillChild()>

If ChildPid is set, kills the corresponding process and unsets ChildPid.
It is up to the caller to save the updated VM object.

=back
=cut

sub KillChild($)
{
  my ($self) = @_;
  kill("TERM", $self->ChildPid) if ($self->ChildPid);
  $self->ChildPid(undef);
}

sub Validate($)
{
  my ($self) = @_;

  if ($self->Type ne "win32" && $self->Type ne "win64" &&
      ($self->Role eq "winetest" || $self->Role eq "extra"))
  {
    return ("Role", "Only win32 and win64 VMs can have a role of '" . $self->Role . "'");
  }
  return $self->SUPER::Validate();
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
      VMStatusChange($self->GetKey(), $self->{OldStatus}, $NewStatus);
    }
  }
}

sub _RunVMTool($$$)
{
  my ($self, $NewStatus, $Args) = @_;

  my $Tool = "LibvirtTool.pl";
  unshift @$Args, "$BinDir/$Tool";

  # There are two $VM->ChildPid race conditions to avoid:
  # - Between the child process and new calls to ScheduleJobs().
  #   We cannot leave setting ChildPid to the child process because then it
  #   may still not be set by the time the next ScheduleJobs() call happens,
  #   which would result in a new child being started.
  #   Note that the status is not guaranteed to change in _RunVMTool() so it
  #   cannot be relied on to avoid this race.
  # - Between _RunVMTool() and the exit of the child process.
  #   The child process may exit before _RunVMTool() gets around to setting
  #   ChildPid after the fork(). This would result in ChildPid remaining set
  #   indefinitely.
  # So set ChildPid in the parent and synchronize with the child so it only
  # starts once this is done.

  # Make sure the child process will use its own database connection
  $self->GetBackEnd()->Close();

  use Fcntl;
  my ($fd_read, $fd_write);
  pipe($fd_read, $fd_write); # For synchronization

  my $Pid = fork();
  if (!defined $Pid)
  {
    close($fd_read);
    close($fd_write);
    return "Unable to start child process: $!";
  }
  if ($Pid)
  {
    close($fd_read);

    # Set the Status and ChildPid
    $self->Status($NewStatus);
    $self->ChildPid($Pid);
    my ($ErrProperty, $ErrMessage) = $self->Save();
    if ($ErrMessage)
    {
      close($fd_write);
      return "Could not set the $Tool pid: $ErrMessage ($ErrProperty)";
    }

    # Let the child go
    close($fd_write);

    return undef;
  }

  # Wait for the parent to set $VM->ChildPid
  close($fd_write);
  sysread($fd_read, $fd_write, 1);
  close($fd_read);

  # Get up-to-date information on the VM and verify the pid. If the parent
  # failed to set the pid it may try to start another process at any time.
  # So abort in order avoid interference.
  require WineTestBot::VMs;
  my $VM = WineTestBot::VMs::CreateVMs()->GetItem($self->GetKey());
  exit 1 if (($VM->ChildPid || 0) != $$);
  $self->GetBackEnd()->Close();

  require WineTestBot::Log;
  WineTestBot::Log::LogMsg("Starting child: @$Args\n");

  # Set up the file descriptors for the new process
  WineTestBot::Log::SetupRedirects();

  $ENV{PATH} = "/usr/bin:/bin";
  exec(@$Args) or
      WineTestBot::Log::LogMsg("Unable to exec $Tool: $!\n");

  # Reset the Status and ChildPid since the exec failed
  $self->Status("offline");
  $self->ChildPid(undef);
  my ($ErrProperty, $ErrMessage) = $self->Save();
  if ($ErrMessage)
  {
    WineTestBot::Log::LogMsg("Could not remove the $Tool pid: $ErrMessage ($ErrProperty)\n");
  }
  exit 1;
}

=pod
=over 12

=item C<RunPowerOff()>

Powers off the VM so that it stops using resources.

The power off need not perform a clean shut down of the guest OS.
This operation can take a long time so it is performed in a separate process.

=back
=cut

sub RunPowerOff($)
{
  my ($self) = @_;
  # This can be used to power off VMs from any state, including 'idle' but we
  # don't want the job scheduler to think it can use the VM while it is being
  # powered off. So force the status to dirty.
  return $self->_RunVMTool("dirty", ["--log-only", "poweroff", $self->GetKey()]);
}

=pod
=over 12

=item C<RunRevert()>

Reverts the VM so that it is ready to run jobs.

Note that in addition to the hypervisor revert operation this implies checking
that it responds to our commands ($WaitForToolsInVM) and possibly letting the
VM settle down ($SleepAfterRevert). If this operation fails the administrator
is notified and the VM is marked as offline.

This operation can take a long time so it is performed in a separate process.

=back
=cut

sub RunRevert($)
{
  my ($self) = @_;
  return $self->_RunVMTool("reverting", ["--log-only", "revert", $self->GetKey()]);
}


package WineTestBot::VMs;

=head1 NAME

WineTestBot::VMs - A VM collection

=head1 DESCRIPTION

This is the collection of VMs the testbot knows about, no matter their type,
role or status.

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::PropertyDescriptor;
use WineTestBot::WineTestBotObjects;

use vars qw (@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateVMs);


BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Name", "VM name", 1, 1, "A", 20),
    CreateBasicPropertyDescriptor("SortOrder", "Display order", !1, 1, "N", 3),
    CreateEnumPropertyDescriptor("Type", "Type of VM", !1, 1, ['win32', 'win64', 'build']),
    CreateEnumPropertyDescriptor("Role", "VM Role", !1, 1, ['extra', 'base', 'winetest', 'retired', 'deleted']),
    CreateEnumPropertyDescriptor("Status", "Current status", !1, 1, ['dirty', 'reverting', 'sleeping', 'idle', 'running', 'off', 'offline', 'maintenance']),
    CreateBasicPropertyDescriptor("ChildPid", "Child process id", !1, !1, "N", 5),
    CreateBasicPropertyDescriptor("VirtURI", "LibVirt URI of the VM", !1, 1, "A", 64),
    CreateBasicPropertyDescriptor("VirtDomain", "LibVirt Domain for the VM", !1, 1, "A", 32),
    CreateBasicPropertyDescriptor("IdleSnapshot", "Name of idle snapshot", !1, 1, "A", 32),
    CreateBasicPropertyDescriptor("Hostname", "The VM hostname", !1, 1, "A", 64),
    CreateBasicPropertyDescriptor("Description", "Description", !1, !1, "A", 40),
    CreateBasicPropertyDescriptor("Details", "VM configuration details", !1, !1, "A", 512),
  );
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::VM->new($self);
}

sub CreateVMs(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::VMs::->new("VMs", "VMs", "VM",
                                 \@PropertyDescriptors, $ScopeObject);
}

sub SortKeysBySortOrder($$)
{
  my ($self, $Keys) = @_;

  # Sort retired and deleted VMs last
  my %RoleOrders = ("retired" => 1, "deleted" => 2);

  my %SortOrder;
  foreach my $Key (@$Keys)
  {
    my $Item = $self->GetItem($Key);
    $SortOrder{$Key} = [$RoleOrders{$Item->Role} || 0, $Item->SortOrder];
  }

  my @SortedKeys = sort {
    my ($soa, $sob) = ($SortOrder{$a}, $SortOrder{$b});
    return @$soa[0] <=> @$sob[0] || @$soa[1] <=> @$sob[1];
  } @$Keys;
  return \@SortedKeys;
}

sub FilterEnabledRole($)
{
  my ($self) = @_;
  # Filter out the disabled VMs, that is the retired and deleted ones
  $self->AddFilter("Role", ["extra", "base", "winetest"]);
}

sub FilterEnabledStatus($)
{
  my ($self) = @_;
  # Filter out the disabled VMs, that is the offline and maintenance ones
  $self->AddFilter("Status", ["dirty", "reverting", "sleeping", "idle", "running", "off"]);
}

sub FilterHypervisors($$)
{
  my ($self, $Hypervisors) = @_;

  $self->AddFilter("VirtURI", $Hypervisors);
}

1;

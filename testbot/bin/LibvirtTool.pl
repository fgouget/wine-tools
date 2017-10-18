#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs poweroff and revert operations on the specified VM.
# These operations can take quite a bit of time, particularly in case of
# network trouble, and thus are best performed in a separate process.
#
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

use WineTestBot::Config;
use WineTestBot::Log;
use WineTestBot::VMs;

my $Debug;
sub Debug(@)
{
  print STDERR @_ if ($Debug);
}

my $LogOnly;
sub Error(@)
{
  print STDERR "$Name0:error: ", @_ if (!$LogOnly);
  LogMsg @_;
}

sub NotifyAdministrator($$)
{
  my ($Subject, $Body) = @_;

  if (open(my $fh, "|/usr/sbin/sendmail -oi -t -odq"))
  {
    LogMsg "Notifying administrator: $Subject\n";
    print $fh <<"EOF";
From: $RobotEMail
To: $AdminEMail
Subject: $Subject

$Body
EOF
    close($fh);
  }
  else
  {
    LogMsg "Could not send administrator notification: $!\n";
    LogMsg "  Subject: $Subject\n";
    LogMsg "  Body: $Body\n";
  }
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/bin:/bin";
delete $ENV{ENV};


# Grab the command line options
my ($Usage, $Action, $VMKey);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--debug")
  {
    $Debug = 1;
  }
  elsif ($Arg eq "--log-only")
  {
    $LogOnly = 1;
  }
  elsif ($Arg =~ /^(?:poweroff|revert)$/)
  {
    $Action = $Arg;
  }
  elsif ($Arg =~ /^(?:-\?|-h|--help)$/)
  {
    $Usage = 0;
    last;
  }
  elsif ($Arg =~ /^-/)
  {
    Error "unknown option '$Arg'\n";
    $Usage = 2;
    last;
  }
  elsif (!defined $VMKey)
  {
    $VMKey = $Arg;
  }
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check parameters
my $VM;
if (!defined $Usage)
{
  if (!defined $Action)
  {
    Error "you must specify the action to perform\n";
    $Usage = 2;
  }
  if (!defined $VMKey)
  {
    Error "you must specify the VM name\n";
    $Usage = 2;
  }
  elsif ($VMKey =~ /^([a-zA-Z0-9_]+)$/)
  {
    $VMKey = $1;
    $VM = CreateVMs()->GetItem($VMKey);
    if (!defined $VM)
    {
      Error "VM $VMKey does not exist\n";
      $Usage = 2;
    }
  }
  else
  {
    Error "'$VMKey' is not a valid VM name\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
  print "Usage: $Name0 [--debug] [--log-only] [--help] (poweroff|revert) VMName\n";
  exit $Usage;
}


#
# Main
#

my $Start = Time();

my $CurrentStatus;

=pod
=over 12

=item C<FatalError()>

Logs the fatal error, notifies the administrator and exits the process.

This function never returns!

=back
=cut

sub FatalError($)
{
  my ($ErrMessage) = @_;
  Error $ErrMessage;

  # Put the VM offline if nobody else modified its status before us
  $VM = CreateVMs()->GetItem($VMKey);
  $VM->Status("offline") if ($VM->Status eq $CurrentStatus);
  $VM->ChildPid(undef);
  my ($ErrProperty, $SaveErrMessage) = $VM->Save();
  if (defined $SaveErrMessage)
  {
    LogMsg "Could not put the $VMKey VM offline: $SaveErrMessage ($ErrProperty)\n";
  }
  elsif ($VM->Status eq "offline")
  {
    NotifyAdministrator("Putting the $VMKey VM offline",
                        "Could not perform the $Action operation on the $VMKey VM:\n".
                        "\n$ErrMessage\n".
                        "The VM has been put offline.");
  }
  exit 1;
}

=pod
=over 12

=item C<ChangeStatus()>

Checks that the VM status has not been tampered with and sets it to the new
value.

Returns a value suitable for the process exit code: 0 in case of success,
1 otherwise.

=back
=cut

sub ChangeStatus($$;$)
{
  my ($From, $To, $Done) = @_;

  # Get the up-to-date VM status
  $VM = CreateVMs()->GetItem($VMKey);
  if (!$VM or (defined $From and $VM->Status ne $From))
  {
    LogMsg "Not changing status\n";
    # Not changing the status is allowed in debug mode so the VM can be
    # put in 'maintenance' mode to avoid interference from the TestBot.
    return $Debug ? 0 : 1;
  }

  $VM->Status($To);
  $VM->ChildPid(undef) if ($Done);
  my ($ErrProperty, $ErrMessage) = $VM->Save();
  if (defined $ErrMessage)
  {
    FatalError("Could not change the $VMKey VM status: $ErrMessage\n");
  }
  $CurrentStatus = $To;
  return 0;
}

sub PowerOff()
{
  # Power off VMs no matter what their initial status is
  $CurrentStatus = $VM->Status;
  my $ErrMessage = $VM->GetDomain()->PowerOff(1);
  FatalError("$ErrMessage\n") if (defined $ErrMessage);

  return ChangeStatus(undef, "off", "done");
}

sub Revert()
{
  my $VM = CreateVMs()->GetItem($VMKey);
  if (!$Debug and $VM->Status ne "reverting")
  {
    Error("The VM is not ready to be reverted (". $VM->Status .")\n");
    return 1;
  }
  $CurrentStatus = "reverting";

  # Some QEmu/KVM versions are buggy and cannot revert a running VM
  Debug(Elapsed($Start), " Powering off the VM\n");
  my $Domain = $VM->GetDomain();
  my $ErrMessage = $Domain->PowerOff(1);
  if (defined $ErrMessage)
  {
    LogMsg "Could not power off $VMKey: $ErrMessage\n";
    LogMsg "Trying the revert anyway...\n";
  }

  # Revert the VM (and power it on if necessary)
  Debug(Elapsed($Start), " Reverting $VMKey to ", $VM->IdleSnapshot, "\n");
  $ErrMessage = $Domain->RevertToSnapshot();
  if (defined $ErrMessage)
  {
    FatalError("Could not revert $VMKey to ". $VM->IdleSnapshot .": $ErrMessage\n");
  }

  # The VM is now sleeping which may allow some tasks to run
  return 1 if (ChangeStatus("reverting", "sleeping"));

  # Check the TestAgent connection. Note that this may take some time
  # if the VM needs to boot first.
  Debug(Elapsed($Start), " Trying the TestAgent connection\n");
  LogMsg "Waiting for ". $VM->Name ." (up to ${WaitForToolsInVM}s per attempt)\n";
  my $TA = $VM->GetAgent();
  $TA->SetConnectTimeout($WaitForToolsInVM);
  my $Success = $TA->Ping();
  $TA->Disconnect();
  if (!$Success)
  {
    $ErrMessage = $TA->GetLastError();
    FatalError("Cannot connect to the $VMKey TestAgent: $ErrMessage\n");
  }

  if ($SleepAfterRevert != 0)
  {
    Debug(Elapsed($Start), " Sleeping\n");
    LogMsg "Letting ". $VM->Name  ." settle down for ${SleepAfterRevert}s\n";
    sleep($SleepAfterRevert);
  }

  return ChangeStatus("sleeping", "idle", "done");
}


my $Rc;
if ($Action eq "poweroff")
{
  $Rc = PowerOff();
}
elsif ($Action eq "revert")
{
  $Rc = Revert();
}
else
{
  Error("Unsupported action $Action!\n");
  $Rc = 1;
}
LogMsg "$Action on $VMKey completed in ", Elapsed($Start), " s\n";

exit $Rc;

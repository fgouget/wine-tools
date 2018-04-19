# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Notification of WineTestBot engine
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

package WineTestBot::Engine::Notify;

=head1 NAME

WineTestBot::Engine::Notify - Engine notification

=cut

use Exporter 'import';
our $RunningInEngine;
our @EXPORT = qw(Shutdown PingEngine JobStatusChange JobCancel
                 JobRestart RescheduleJobs VMStatusChange
                 WinePatchMLSubmission WinePatchWebSubmission GetScreenshot);
our @EXPORT_OK = qw($RunningInEngine);

use Socket;
use WineTestBot::Config;


sub SendCmdReceiveReply($)
{
  my ($Cmd) = @_;

  if (defined($RunningInEngine))
  {
    return "1";
  }

  if (! socket(SOCK, PF_UNIX, SOCK_STREAM, 0))
  {
    return "0Unable to create socket: $!";
  }
  if (! connect(SOCK, sockaddr_un("$DataDir/socket/engine")))
  {
    return "0Unable to connect to engine: $!";
  }

  if (! syswrite(SOCK, $Cmd, length($Cmd)))
  {
    return "0Unable to send command to engine: $!";
  }

  my $Reply = "";
  my $Buf;
  while (my $Len = sysread(SOCK, $Buf, 128))
  {
    $Reply .= $Buf;
  }

  close(SOCK);

  return $Reply;
}

sub Shutdown($$)
{
  my ($KillTasks, $KillVMs) = @_;

  $KillTasks ||= 0;
  $KillVMs ||= 0;
  my $Reply = SendCmdReceiveReply("shutdown $KillTasks $KillVMs\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return undef;
  }

  return substr($Reply, 1);
}

sub PingEngine()
{
  my $Reply = SendCmdReceiveReply("ping\n");
  return 1 <= length($Reply) && substr($Reply, 0, 1) eq "1";
}

sub JobStatusChange($$$)
{
  my ($JobKey, $OldStatus, $NewStatus) = @_;

  my $Reply = SendCmdReceiveReply("jobstatuschange $JobKey $OldStatus $NewStatus\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return undef;
  }
 
  return substr($Reply, 1);
}

sub JobCancel($)
{
  my ($JobKey) = @_;

  my $Reply = SendCmdReceiveReply("jobcancel $JobKey\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return undef;
  }
 
  return substr($Reply, 1);
}

sub JobRestart($)
{
  my ($JobKey) = @_;

  my $Reply = SendCmdReceiveReply("jobrestart $JobKey\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return undef;
  }

  return substr($Reply, 1);
}

sub RescheduleJobs()
{
  my $Reply = SendCmdReceiveReply("reschedulejobs\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return undef;
  }
 
  return substr($Reply, 1);
}

sub VMStatusChange($$$)
{
  my ($VMKey, $OldStatus, $NewStatus) = @_;

  my $Reply = SendCmdReceiveReply("vmstatuschange $VMKey $OldStatus $NewStatus\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return undef;
  }
 
  return substr($Reply, 1);
}

sub WinePatchMLSubmission()
{
  my $Reply = SendCmdReceiveReply("winepatchmlsubmission\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return undef;
  }
 
  return substr($Reply, 1);
}

sub WinePatchWebSubmission()
{
  my $Reply = SendCmdReceiveReply("winepatchwebsubmission\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return undef;
  }
 
  return substr($Reply, 1);
}

sub GetScreenshot($)
{
  my ($VMName) = @_;

  my $Reply = SendCmdReceiveReply("getscreenshot $VMName\n");
  if (length($Reply) < 1)
  {
    return "Unrecognized reply received from engine";
  }
  if (substr($Reply, 0, 1) eq "1")
  {
    return (undef, substr($Reply, 1));
  }
 
  return (substr($Reply, 1), undef);
}

1;

# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014 Francois Gouget
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

package WineTestBot::Task;

=head1 NAME

WineTestBot::Task - A task associated with a given WineTestBot::Step object

=head1 DESCRIPTION

A WineTestBot::Step is composed of one or more Tasks, each responsible for
performing that Step in a WineTestBot::VM virtual machine. For instance a Step
responsible for running a given test would have one Task object for each
virtual machine that the test must be performed in.

=cut

use POSIX qw(:errno_h);
use File::Path;
use ObjectModel::BackEnd;
use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::Steps;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  # Make up an initial, likely unique, key so the Task can be added to the
  # Collection
  my $Keys = $Collection->GetKeys();
  $self->No(scalar @$Keys + 1);

  $self->Status("queued");

  $self->SUPER::InitializeNew($Collection);
}

sub GetDir($)
{
  my ($self) = @_;
  my ($JobId, $StepNo, $TaskNo) = @{$self->GetMasterKey()};
  return "$DataDir/jobs/$JobId/$StepNo/$TaskNo";
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

sub _SetupTask($$)
{
  my ($VM, $self) = @_;

  # Remove the previous run's files if any
  $self->RmTree();

  # Capture Perl errors in the task's generic error log
  my $TaskDir = $self->CreateDir();
  if (open(STDERR, ">>", "$TaskDir/err"))
  {
    # Make sure stderr still flushes after each print
    my $tmp=select(STDERR);
    $| = 1;
    select($tmp);
  }
  else
  {
    require WineTestBot::Log;
    WineTestBot::Log::LogMsg("unable to redirect stderr to '$TaskDir/err': $!\n");
  }
}

=pod
=over 12

=item C<Run()>

Starts a script in the background to execute the specified task. The command is
of the form:

    ${ProjectName}Run${Type}.pl ${JobId} ${StepNo} ${TaskNo}

Where $Type corresponds to the Task's type.

=back
=cut

sub Run($$)
{
  my ($self, $Step) = @_;

  my ($JobId, $StepNo, $TaskNo) = @{$self->GetMasterKey()};
  my $Script = $Step->Type eq "build" ? "Build" :
               $Step->Type eq "reconfig" ? "Reconfig" :
               "Task";
  my $Args = ["$BinDir/${ProjectName}Run$Script.pl", "--log-only",
              $JobId, $StepNo, $TaskNo];

  my $ErrMessage = $self->VM->Run("running", $Args, \&_SetupTask, $self);
  if (!$ErrMessage)
  {
    $self->Status("running");
    $self->Started(time());
    my $_ErrProperty;
    ($_ErrProperty, $ErrMessage) = $self->Save();
  }
  return $ErrMessage;
}

sub CanRetry($)
{
  my ($self) = @_;
  return ($self->TestFailures || 0) + 1 < $MaxTaskTries;
}

sub UpdateStatus($$)
{
  my ($self, $Skip) = @_;

  my $Status = $self->Status;
  my $VM = $self->VM;

  if ($Status eq "running" and
      ($VM->Status ne "running" or !$VM->HasRunningChild()))
  {
    my ($JobId, $StepNo, $TaskNo) = @{$self->GetMasterKey()};
    my $OldUMask = umask(002);
    my $TaskDir = $self->CreateDir();
    if (open TASKLOG, ">>$TaskDir/err")
    {
      print TASKLOG "TestBot process died unexpectedly\n";
      close TASKLOG;
    }
    umask($OldUMask);
    # This probably indicates a bug in the task script.
    # Don't requeue the task to avoid an infinite loop.
    require WineTestBot::Log;
    WineTestBot::Log::LogMsg("Child process for task $JobId/$StepNo/$TaskNo died unexpectedly\n");
    $self->Status("boterror");
    $self->Save();

    if ($VM->Status eq "running")
    {
      $VM->Status('dirty');
      $VM->ChildPid(undef);
      $VM->Save();
      $VM->RecordResult(undef, "boterror process died");
    }
    # else it looks like this is not our VM anymore

    $Status = "boterror";
  }
  elsif ($Skip && $Status eq "queued")
  {
    $Status = "skipped";
    $self->Status("skipped");
    $self->Save();
  }
  return $Status;
}


package WineTestBot::Tasks;

=head1 NAME

WineTestBot::Tasks - A collection of WineTestBot::Task objects

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::VMs;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateTasks);

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("No", "Task no",  1,  1, "N", 2),
    CreateEnumPropertyDescriptor("Status", "Status",  !1,  1, ['queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled', 'skipped']),
    CreateItemrefPropertyDescriptor("VM", "VM", !1,  1, \&CreateVMs, ["VMName"]),
    CreateBasicPropertyDescriptor("Timeout", "Timeout", !1, 1, "N", 4),
    CreateBasicPropertyDescriptor("CmdLineArg", "Command line args", !1, !1, "A", 256),
    CreateBasicPropertyDescriptor("Started", "Execution started", !1, !1, "DT", 19),
    CreateBasicPropertyDescriptor("Ended", "Execution ended", !1, !1, "DT", 19),
    CreateBasicPropertyDescriptor("TestFailures", "Number of test failures", !1, !1, "N", 6),
  );
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Task->new($self);
}

sub CreateTasks(;$$)
{
  my ($ScopeObject, $Step) = @_;
  return WineTestBot::Tasks->new("Tasks", "Tasks", "Task",
                                 \@PropertyDescriptors, $ScopeObject, $Step);
}

1;

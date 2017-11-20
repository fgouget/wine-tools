# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
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

package WineTestBot::Step;

=head1 NAME

WineTestBot::Step - A Job's Step

=head1 DESCRIPTION

A Job is composed of multiple Steps that each do a specific operation: build
the test executable, or run a given test, etc. A Step is in turn composed of
a WineTestBot::Task object for each VM it should be run on.

=cut

use File::Copy;
use File::Path;

use WineTestBot::Config;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->Status("queued");
  my $Keys = $Collection->GetKeys();
  $self->No(scalar @$Keys + 1);
  $self->Type("single");
  $self->InStaging(1);
  $self->DebugLevel(1);
  $self->ReportSuccessfulTests(!1);

  $self->SUPER::InitializeNew($Collection);
}

sub GetDir($)
{
  my ($self) = @_;
  my ($JobId, $StepNo) = @{$self->GetMasterKey()};
  return "$DataDir/jobs/$JobId/$StepNo";
}

sub CreateDir($)
{
  my ($self) = @_;
  my $Dir = $self->GetDir();
  File::Path::make_path($Dir, mode => 0775);
  return $Dir;
}

sub RmTree($)
{
  my ($self) = @_;
  my $Dir = $self->GetDir();
  File::Path::remove_tree($Dir);
}

sub HandleStaging($$)
{
  my ($self) = @_;

  if (! $self->InStaging)
  {
    return undef;
  }

  my $FileName = $self->FileName;
  if ($FileName !~ m/^[0-9a-z-]+_(.*)$/)
  {
    return "Can't split staging filename";
  }
  my $BaseName = $1;
  my $StagingFileName = "$DataDir/staging/$FileName";
  my $StepDir = $self->CreateDir();
  my $FinalFileName = "$StepDir/$BaseName";
  if (!move($StagingFileName, $FinalFileName))
  {
    return "Could not move the staging file: $!";
  }

  $self->FileName($BaseName);
  $self->InStaging(!1);
  my ($ErrProperty, $ErrMessage) = $self->Save();

  return $ErrMessage;
}

sub UpdateStatus($$)
{
  my ($self, $Skip) = @_;

  my $Status = $self->Status;
  return $Status if ($Status ne "queued" && $Status ne "running");

  my %Has;
  my $Tasks = $self->Tasks;
  foreach my $TaskKey (@{$Tasks->GetKeys()})
  {
    my $Task = $Tasks->GetItem($TaskKey);
    $Has{$Task->UpdateStatus($Skip)} = 1;
  }

  # Inherit the tasks most significant status.
  # Note that one or more tasks may have been requeued during the cleanup phase
  # of the server startup. So this step may regress from 'running' back to
  # 'queued'. This means all possible task status values must be considered.
  foreach my $TaskStatus ("running", "boterror", "badpatch", "badbuild", "canceled", "skipped", "completed", "queued")
  {
    if ($Has{$TaskStatus})
    {
      if ($Has{"queued"})
      {
        # Either nothing ran so this step is still / again 'queued', or not
        # everything has been run yet which means it's still 'running'.
        $Status = $TaskStatus eq "queued" ? "queued" : "running";
      }
      else
      {
        $Status = $TaskStatus;
      }
      $self->Status($Status);
      $self->Save();
      last;
    }
  }

  return $Status;
}


package WineTestBot::Steps;

=head1 NAME

WineTestBot::Steps - A collection of Job Steps

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::DetailrefPropertyDescriptor;
use ObjectModel::PropertyDescriptor;
use WineTestBot::Tasks;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateSteps);

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("No", "Step no",  1,  1, "N", 2),
    CreateEnumPropertyDescriptor("Status", "Status",  !1,  1, ['queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled', 'skipped']),
    CreateEnumPropertyDescriptor("Type", "Step type",  !1,  1, ['suite', 'single', 'build', 'reconfig']),
    CreateBasicPropertyDescriptor("FileName", "File name",  !1,  1, "A", 100),
    CreateEnumPropertyDescriptor("FileType", "File type",  !1,  1, ['exe32', 'exe64', 'patchdlls', 'patchprograms']),
    CreateBasicPropertyDescriptor("InStaging", "File is in staging area", !1, 1, "B", 1),
    CreateBasicPropertyDescriptor("DebugLevel", "Debug level (WINETEST_DEBUG)", !1, 1, "N", 2),
    CreateBasicPropertyDescriptor("ReportSuccessfulTests", "Report successful tests (WINETEST_REPORT_SUCCESS)", !1, 1, "B", 1),
    CreateDetailrefPropertyDescriptor("Tasks", "Tasks", !1, !1, \&CreateTasks),
  );
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Step->new($self);
}

sub CreateSteps(;$$)
{
  my ($ScopeObject, $Job) = @_;

  return WineTestBot::Steps->new("Steps", "Steps", "Step",
                                 \@PropertyDescriptors, $ScopeObject, $Job);
}

1;

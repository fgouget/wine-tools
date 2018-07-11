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

A Job is composed of one or more Steps that each perform one operation. A
Step is in turn composed of one WineTestBot::Task object for each VM that the
Step should be run on.

A Step's lifecyle is as follows:
=over

=item *
A Step is created with Status set to queued which means it is ready to be run
as soon as the PreviousNo Step has completed, or immediately if PreviousNo is
not set.

=item *
Once one of the Step's Task is running the Step's Status is changed to
running.

=item *
Once all the Tasks in the Step have completed, the Step's Status is set to one
of the "completion" Status values according to the overall success of its
Tasks: completed, badpatch, etc.

=item *
If the PreviousNo Step failed then the Status field and that of all its Tasks
is set to skip; and the Step will not be run.

=item *
If a Step is canceled by the user, then the Status field is set to canceled if
the Step was running, and to skipped if it was queued.

=back

If FileName is set it identifies a file that the Step needs for its operation.
That file will either be in the directory of the PreviousNo Step that produced
it, or in the directory of the job if it was provided by the user.
Conversely a Step's Task(s) may produce one or more files. These are all stored
in that Step's directory and may be used by one or more Steps.

Note that the PreviousNo relation will prevent the deletion of the target Step.
It is the responsibility of the caller to delete the Steps in a suitable order,
or to reset their PreviousNo fields beforehand.

=cut

use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotItem);

use File::Copy;
use File::Path;

use WineTestBot::Config;


sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  # Make up an initial, likely unique, key so the Step can be added to the
  # Collection
  my $Keys = $Collection->GetKeys();
  $self->No(scalar @$Keys + 1);

  $self->Status("queued");
  $self->Type("single");
  $self->FileType("none");
  $self->DebugLevel(1);
  $self->ReportSuccessfulTests(!1);

  $self->SUPER::InitializeNew($Collection);
}

=pod
=over 12

=item C<Validate()>

Enforces strict ordering to avoid loops.

Note that a side effect is that processing steps in increasing step number
order is sufficient to ensure the dependencies are processed first.

=back
=cut

sub Validate($)
{
  my ($self) = @_;

  if ($self->PreviousNo and $self->PreviousNo >= $self->No)
  {
    return ("PreviousNo", "The previous step number must be less than this one's.");
  }
  if (defined $self->FileName and $self->FileType eq "none")
  {
    return ("FileType", "A file has been specified but no FileType");
  }
  return $self->SUPER::Validate();
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
  mkpath($Dir, 0, 0775);
  return $Dir;
}

sub RmTree($)
{
  my ($self) = @_;
  my $Dir = $self->GetDir();
  rmtree($Dir);
}

sub GetFullFileName($)
{
  my ($self) = @_;

  return undef if (!defined $self->FileName);

  my ($JobId, $StepNo) = @{$self->GetMasterKey()};
  my $Path = "$DataDir/jobs/$JobId/";
  $Path .= $self->PreviousNo ."/" if ($self->PreviousNo);
  return $Path . $self->FileName;
}

sub UpdateStatus($$)
{
  my ($self, $Skip) = @_;

  my $Status = $self->Status;
  return $Status if ($Status ne "queued" && $Status ne "running");

  my %Has;
  map { $Has{$_->UpdateStatus($Skip)} = 1 } (@{$self->Tasks->Clone()->GetItems()});
  $Has{completed} = 1 if (!%Has); # This step has no task!

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

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
BEGIN
{
  our @ISA = qw(WineTestBot::WineTestBotCollection);
  our @EXPORT = qw(CreateSteps);
}

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::DetailrefPropertyDescriptor;
use WineTestBot::Tasks;


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Step->new($self);
}

my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("No", "Step no",  1,  1, "N", 2),
  CreateBasicPropertyDescriptor("PreviousNo", "Previous step", !1, !1, "N", 2),
  CreateEnumPropertyDescriptor("Status", "Status",  !1,  1, ['queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled', 'skipped']),
  CreateEnumPropertyDescriptor("Type", "Step type",  !1,  1, ['suite', 'single', 'build', 'reconfig']),
  CreateBasicPropertyDescriptor("FileName", "File name",  !1, !1, "A", 100),
  CreateEnumPropertyDescriptor("FileType", "File type",  !1,  1, ['none', 'exe32', 'exe64', 'patchdlls', 'patchprograms']),
  CreateBasicPropertyDescriptor("DebugLevel", "Debug level (WINETEST_DEBUG)", !1, 1, "N", 2),
  CreateBasicPropertyDescriptor("ReportSuccessfulTests", "Report successful tests (WINETEST_REPORT_SUCCESS)", !1, 1, "B", 1),
  CreateDetailrefPropertyDescriptor("Tasks", "Tasks", !1, !1, \&CreateTasks),
);
SetDetailrefKeyPrefix("Step", @PropertyDescriptors);
my @FlatPropertyDescriptors = (
  CreateBasicPropertyDescriptor("JobId", "Job id", 1, 1, "S", 5),
  @PropertyDescriptors
);

=pod
=over 12

=item C<CreateSteps()>

When given a Job object returns a collection containing the corresponding
steps. In this case the Step objects don't store the key of their parent.

If no Job object is specified all the table rows are returned and the Step
objects have a JobId property.

=back
=cut

sub CreateSteps(;$$)
{
  my ($ScopeObject, $Job) = @_;

  return WineTestBot::Steps->new("Steps", "Steps", "Step",
      $Job ? \@PropertyDescriptors : \@FlatPropertyDescriptors,
      $ScopeObject, $Job);
}

1;

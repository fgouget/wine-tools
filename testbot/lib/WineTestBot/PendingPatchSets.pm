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

package WineTestBot::PendingPatchSet;

=head1 NAME

WineTestBot::PendingPatchSet - An object tracking a pending patchset

=head1 DESCRIPTION

A patchset is a set of patches that depend on each other. They are numbered so
that one knows in which order to apply them. This is typically indicated by a
subject of the form '[3/5] Subject'. This means one must track which patchset
a patch belongs to so it is tested (and applied) together with the earlier
parts rather than in isolation. Furthermore the parts of the set may arrive in
the wrong order so processing of later parts must be deferred until the earlier
ones have been received.

The WineTestBot::PendingPatchSet class is where this tracking is implemented.

=cut

use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotItem);

use WineTestBot::Config;
use WineTestBot::Utils;


=pod
=over 12

=item C<CheckSubsetComplete()>

Returns true if all the patches needed for the specified part in the patchset
have been received.

=back
=cut

sub CheckSubsetComplete($$)
{
  my ($self, $MaxPart) = @_;

  my $Parts = $self->Parts;
  my $MissingPart = !1;
  for (my $PartNo = 1; $PartNo <= $MaxPart && ! $MissingPart;
       $PartNo++)
  {
    $MissingPart = ! defined($Parts->GetItem($PartNo));
  }

  return ! $MissingPart;
}

=pod
=over 12

=item C<CheckComplete()>

Returns true if all the patches of the patchset have been received.

=back
=cut

sub CheckComplete($)
{
  my ($self) = @_;

  return $self->CheckSubsetComplete($self->TotalParts)
}

=pod
=over 12

=item C<SubmitSubset()>

Combines the patches leading to the specified part in the patchset, and then
calls WineTestBot::Patch::Submit() to create the corresponding job.

=back
=cut

sub SubmitSubset($$$)
{
  my ($self, $MaxPart, $FinalPatch) = @_;

  my ($CombinedFile, $CombinedFileName) = OpenNewFile("$DataDir/staging", "_patch");
  return "Could not create a combined patch file: $!" if (!$CombinedFile);

  my $Parts = $self->Parts;
  for (my $PartNo = 1; $PartNo <= $MaxPart; $PartNo++)
  {
    my $Part = $Parts->GetItem($PartNo);
    if (defined $Part and
        open(my $PartFile, "<" , "$DataDir/patches/" . $Part->Patch->Id))
    {
      map { print $CombinedFile $_; } <$PartFile>;
      close($PartFile);
    }
  }
  close($CombinedFile);

  my $ErrMessage = $FinalPatch->Submit($CombinedFileName, 1);
  unlink($CombinedFileName);

  return $ErrMessage;
}

=pod
=over 12

=item C<Submit()>

Submits the last patch in the patchset.

=back
=cut

sub Submit($$)
{
  my ($self, $FinalPatch) = @_;

  return $self->SubmitSubset($self->TotalParts, $FinalPatch);
}

package WineTestBot::PendingPatchSets;

=head1 NAME

WineTestBot::PendingPatchSets - A collection of WineTestBot::PendingPatchSet objects

=cut

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
BEGIN
{
  our @ISA = qw(WineTestBot::WineTestBotCollection);
  our @EXPORT = qw(CreatePendingPatchSets);
}

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::DetailrefPropertyDescriptor;
use WineTestBot::PendingPatches;
use WineTestBot::Utils;


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::PendingPatchSet->new($self);
}

my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("EMail", "EMail of series author", 1, 1, "A", 40),
  CreateBasicPropertyDescriptor("TotalParts", "Expected number of parts in series", 1, 1, "N", 2),
  CreateDetailrefPropertyDescriptor("Parts", "Parts received so far", !1, !1, \&CreatePendingPatches),
);
SetDetailrefKeyPrefix("PendingPatchSet", @PropertyDescriptors);

=pod
=over 12

=item C<CreatePendingPatchSets()>

Creates a collection of PendingPatchSet objects.

=back
=cut

sub CreatePendingPatchSets(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::PendingPatchSets->new("PendingPatchSets", "PendingPatchSets", "PendingPatchSet", \@PropertyDescriptors, $ScopeObject);
}

=pod
=over 12

=item C<NewSubmission()>

Adds a new part to the current patchset and submits it as well as all the
other parts for which all the previous parts are available. If the new part
makes the patchset complete, then the patchset itself is deleted.

=back
=cut

sub NewSubmission($$)
{
  my ($self, $Patch) = @_;
  if (! defined($Patch->FromEMail))
  {
    $Patch->Disposition("Unable to determine series author");
    return undef;
  }

  my $Subject = $Patch->Subject;
  $Subject =~ s/32\/64//;
  $Subject =~ s/64\/32//;
  $Subject =~ m/(\d+)\/(\d+)/;
  my $PartNo = int($1);
  my $MaxPartNo = int($2);

  my $Set = $self->GetItem($self->CombineKey($Patch->FromEMail, $MaxPartNo));
  if (! defined($Set))
  {
    $Set = $self->Add();
    $Set->EMail($Patch->FromEMail);
    $Set->TotalParts($MaxPartNo);
  }

  my $Parts = $Set->Parts;
  my $Part = $Parts->GetItem($PartNo);
  if (! defined($Part))
  {
    $Part = $Parts->Add();
    $Part->No($PartNo);
  }

  $Part->Patch($Patch);

  my ($ErrKey, $ErrProperty, $ErrMessage) = $self->Save();
  if (defined($ErrMessage))
  {
    $Patch->Disposition("Error occurred during series processing");
  }

  if (! $Set->CheckSubsetComplete($PartNo))
  {
    $Patch->Disposition("Set not complete yet");
  }
  else
  {
    my $AllPartsAvailable = 1;
    while ($PartNo <= $Set->TotalParts && $AllPartsAvailable &&
           ! defined($ErrMessage))
    {
      my $Part = $Parts->GetItem($PartNo);
      if (defined($Part))
      {
        $ErrMessage = $Set->SubmitSubset($PartNo, $Part->Patch);
        if (!defined $ErrMessage)
        {
          (my $ErrProperty, $ErrMessage) = $Part->Patch->Save();
        }
      }
      else
      {
        $AllPartsAvailable = !1;
      }
      $PartNo++;
    }
    if ($AllPartsAvailable && ! defined($ErrMessage))
    {
      $self->DeleteItem($Set);
    }
  }

  return $ErrMessage;
}

=pod
=over 12

=item C<CheckForCompleteSet()>

Goes over the pending patchsets and submits the patches for all those that
are complete. See WineTestBot::PendingPatchSet::Submit().
The WineTestBot::PendingPatchSet objects of all complete patchsets are also
deleted.

Note that this only submits the last patch in the set, because each part of a
patchset is submitted as it becomes available so the earlier parts are supposed
to have been submitted already.

=back
=cut

sub CheckForCompleteSet($)
{
  my ($self) = @_;

  my ($Submitted, @ErrMessages);
  foreach my $Set (@{$self->GetItems()})
  {
    if ($Set->CheckComplete())
    {
      my $Patch = $Set->Parts->GetItem($Set->TotalParts)->Patch;
      my $SetErrMessage = $Set->Submit($Patch);
      if (defined $SetErrMessage)
      {
        push @ErrMessages, $SetErrMessage;
      }
      else
      {
        $Patch->Save();
        $Submitted = 1;
      }
      $self->DeleteItem($Set);
    }
  }

  return ($Submitted, @ErrMessages ? join("; ", @ErrMessages) : undef);
}

1;

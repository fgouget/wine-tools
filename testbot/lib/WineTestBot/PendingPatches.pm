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

package WineTestBot::PendingPatch;

=head1 NAME

WineTestBot::PendingPatch - Tracks the patches of an incomplete series

=head1 DESCRIPTION

Ties a WineTestBot::Patch object to the WineTestBot::PendingPatchSet object
identifying the patch series it belongs to.

=cut

use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotItem);


package WineTestBot::PendingPatches;

=head1 NAME

WineTestBot::PendingPatches - A collection of WineTestBot::PendingPatch objects

=cut

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
BEGIN
{
  our @ISA = qw(WineTestBot::WineTestBotCollection);
  our @EXPORT = qw(CreatePendingPatches);
}

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::Patches;


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::PendingPatch->new($self);
}

my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("No", "Part no", 1, 1, "N", 2),
  CreateItemrefPropertyDescriptor("Patch", "Submitted via patch", !1, 1, \&WineTestBot::Patches::CreatePatches, ["PatchId"]),
);
my @FlatPropertyDescriptors = (
  CreateBasicPropertyDescriptor("PendingPatchSetEMail", "EMail of series author", 1, 1, "A", 40),
  CreateBasicPropertyDescriptor("PendingPatchSetTotalParts", "Expected number of parts in series", 1, 1, "N", 2),
  @PropertyDescriptors
);

=pod
=over 12

=item C<CreatePendingPatches()>

When given a PendingPatchSet object returns a collection containing the
corresponding parts. In this case the PendingPatch objects don't store the
key of their parent.

If no PendingPatchSet object is specified all the table rows are returned and
the PendingPatch objects have PendingPatchSetEMail and
PendingPatchSetTotalParts properties.

=back
=cut

sub CreatePendingPatches(;$$)
{
  my ($ScopeObject, $PendingPatchSet) = @_;

  return WineTestBot::PendingPatches->new(
      "PendingPatches", "PendingPatches", "PendingPatch",
      $PendingPatchSet ? \@PropertyDescriptors : \@FlatPropertyDescriptors,
      $ScopeObject, $PendingPatchSet);
}

1;

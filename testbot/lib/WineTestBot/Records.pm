# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2017 Francois Gouget
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

package WineTestBot::Record;

=head1 NAME

WineTestBot::Record - records part of an event or the state of the TestBot.

=head1 DESCRIPTION

A Record is created to save information about an event or part of the state of
the TestBot at a given time. A full description of said event or state may
require a variable number of Records so they are part of a RecordGroup which
identifies which other Records relate to the same event or state.
The RecordGroup also stores the timestamp of the event or state.

The point of the Record objects is to keep a record of the activity of the
TestBot. By putting them together it is possible to rebuild what the TestBot
did and when, for debugging or performance analysis. The amount of details is
only limited by the amount of data dumped into the Records table.

=cut

use WineTestBot::Config;
use WineTestBot::WineTestBotObjects;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->SUPER::InitializeNew($Collection);
}


package WineTestBot::Records;

=head1 NAME

WineTestBot::Records - A collection of WineTestBot::Record objects

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::PropertyDescriptor;
use WineTestBot::WineTestBotObjects;

use vars qw (@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateRecords);


BEGIN
{
  @PropertyDescriptors = (
    CreateEnumPropertyDescriptor("Type",   "Type",   1,  1, ['engine', 'tasks', 'vmresult', 'vmstatus']),
    CreateBasicPropertyDescriptor("Name",  "Name",   1,  1, "A", 96),
    CreateBasicPropertyDescriptor("Value", "Value", !1, !1, "A", 64),
  );
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Record->new($self);
}

sub CreateRecords(;$$)
{
  my ($ScopeObject, $RecordGroup) = @_;
  return WineTestBot::Records->new("Records", "Records", "Record",
                                   \@PropertyDescriptors, $ScopeObject,
                                   $RecordGroup);
}

=pod
=over 12

=item C<AddRecord()>

This is a convenience function for adding a new record to a Records collection
and setting its properties at the same time.

=back
=cut

sub AddRecord($$$;$)
{
  my ($self, $Type, $Name, $Value) = @_;

  my $Record = $self->Add();
  my $TemporaryKey = $Record->GetKey();
  $Record->Type($Type);
  $Record->Name($Name);
  $Record->Value($Value) if (defined $Value);
  $self->KeyChanged($TemporaryKey, $Record->GetKey());

  return $Record;
}

1;

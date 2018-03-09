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

package WineTestBot::RecordGroup;

=head1 NAME

WineTestBot::RecordGroup - a group of related history records

=head1 DESCRIPTION

A RecordGroup is a group of WineTestBot::Record objects describing an event
or the state of the TestBot at at a given time.

=cut

use WineTestBot::WineTestBotObjects;
use WineTestBot::Config;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->Timestamp(time());

  $self->SUPER::InitializeNew($Collection);
}


package WineTestBot::RecordGroups;

=head1 NAME

WineTestBot::RecordGroups - A collection of WineTestBot::RecordGroup objects

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::DetailrefPropertyDescriptor;
use WineTestBot::WineTestBotObjects;
use WineTestBot::Records;

use vars qw (@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateRecordGroups &CompareRecordGroups &SaveRecord);


BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Id",        "Group id",   1,  1, "S",  6),
    CreateBasicPropertyDescriptor("Timestamp", "Timestamp", !1,  1, "DT", 19),
    CreateDetailrefPropertyDescriptor("Records", "Records", !1, !1, \&CreateRecords),
  );
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::RecordGroup->new($self);
}

sub CreateRecordGroups(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::RecordGroups->new("RecordGroups", "RecordGroups", "RecordGroup",
                                        \@PropertyDescriptors, $ScopeObject);
}

sub CompareRecordGroups($$)
{
  my ($RecordGroup1, $RecordGroup2) = @_;

  # The Timestamps have a 1 second granularity and may have duplicates.
  # So use the Id to break ties.
  return $RecordGroup1->Timestamp <=> $RecordGroup2->Timestamp ||
         $RecordGroup1->Id <=> $RecordGroup2->Id;
}

=pod
=over 12

=item C<SaveRecord()>

Creates and saves a standalone record.

=back
=cut

sub SaveRecord($$;$)
{
  my ($Type, $Name, $Value) = @_;

  my $RecordGroups = CreateRecordGroups();
  my $Records = $RecordGroups->Add()->Records;
  $Records->AddRecord($Type, $Name, $Value);

  return $RecordGroups->Save();
}

1;

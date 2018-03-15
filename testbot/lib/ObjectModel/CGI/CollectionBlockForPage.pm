# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Collection block for list pages
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

package ObjectModel::CGI::CollectionBlockForPage;

=head1 NAME

ObjectModel::CGI::CollectionBlockForPage - Collection block for list pages

=cut

use ObjectModel::CGI::CollectionBlock;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::CGI::CollectionBlock Exporter);

sub CallGenerateFormStart($)
{
  my ($self) = @_;

  $self->{EnclosingPage}->GenerateFormStart($self);
}

sub CallGenerateFormEnd($)
{
  my ($self) = @_;

  $self->{EnclosingPage}->GenerateFormEnd($self);
}

sub CallGenerateHeaderRow($$$)
{
  my ($self, $PropertyDescriptors, $Actions) = @_;

  $self->{EnclosingPage}->GenerateHeaderRow($self, $PropertyDescriptors, $Actions);
}

sub CallGenerateDataRow($$$$$$)
{
  my ($self, $Item, $PropertyDescriptors, $DetailsPage, $Class, $Actions) = @_;

  $self->{EnclosingPage}->GenerateDataRow($self, $Item, $PropertyDescriptors, $DetailsPage, $Class, $Actions);
}

sub CallGenerateDataCell($$$$)
{
  my ($self, $Item, $PropertyDescriptor, $DetailsPage) = @_;

  return $self->{EnclosingPage}->GenerateDataCell($self, $Item, $PropertyDescriptor, $DetailsPage);
}

sub CallGetDetailsPage($)
{
  my ($self) = @_;

  return $self->{EnclosingPage}->GetDetailsPage($self);
}

sub CallGetItemActions($)
{
  my ($self) = @_;

  return $self->{EnclosingPage}->GetItemActions($self);
}

sub CallGetActions($)
{
  my ($self) = @_;

  return $self->{EnclosingPage}->GetActions($self);
}

sub CallDisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  return $self->{EnclosingPage}->DisplayProperty($self, $PropertyDescriptor);
}

sub CallGetDisplayValue($$$)
{
  my ($self, $Item, $PropertyDescriptor) = @_;

  return $self->{EnclosingPage}->GetDisplayValue($self, $Item, $PropertyDescriptor);
}

sub CallOnItemAction($$$)
{
  my ($self, $Item, $Action) = @_;

  return $self->{EnclosingPage}->OnItemAction($self, $Item, $Action);
}

sub CallSortKeys($$)
{
  my ($self, $Keys) = @_;

  return $self->{EnclosingPage}->SortKeys($self, $Keys);
}

1;

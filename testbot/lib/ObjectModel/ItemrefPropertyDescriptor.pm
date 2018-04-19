# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
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

package ObjectModel::ItemrefPropertyDescriptor;

=head1 NAME

ObjectModel::ItemrefPropertyDescriptor - A property referencing an ObjectModel::Item stored in another table

=cut

use Exporter 'import';
use ObjectModel::PropertyDescriptor;
our @ISA = qw(ObjectModel::PropertyDescriptor);
our @EXPORT = qw(CreateItemrefPropertyDescriptor);

sub _initialize($$$)
{
  my ($self, $Creator, $ColNames) = @_;

  $self->{Class} = "Itemref";
  $self->{Creator} = $Creator;
  $self->{ColNames} = $ColNames;

  $self->SUPER::_initialize();
}

sub GetCreator($)
{
  my ($self) = @_;

  return $self->{Creator};
}

sub GetColNames($)
{
  my ($self) = @_;

  return $self->{ColNames};
}

sub ValidateValue($$$)
{
  my ($self, $Value, $IsNew) = @_;

  if ($self->GetIsRequired() && ! defined($Value))
  {
    return $self->GetDisplayName() .  ": Must be entered";
  }

  return undef;
}

sub CreateItemrefPropertyDescriptor($$$$$$)
{
  my ($Name, $DisplayName, $IsKey, $IsRequired, $Creator, $ColNames) = @_;
  return ObjectModel::ItemrefPropertyDescriptor->new($Name, $DisplayName, $IsKey, $IsRequired, $Creator, $ColNames);
}

1;

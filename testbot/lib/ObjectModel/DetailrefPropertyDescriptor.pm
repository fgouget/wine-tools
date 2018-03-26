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

package ObjectModel::DetailrefPropertyDescriptor;

=head1 NAME

ObjectModel::DetailrefPropertyDescriptor - A reference to a collection of related objects

=cut

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::PropertyDescriptor Exporter);
@EXPORT = qw(&CreateDetailrefPropertyDescriptor &SetDetailrefKeyPrefix);

sub _initialize($$)
{
  my ($self, $Creator) = @_;

  $self->{Class} = "Detailref";
  $self->{Creator} = $Creator;

  $self->SUPER::_initialize();
}

sub GetColNames($)
{
  #my ($self) = @_;
  return [];
}

sub GetCreator($)
{
  my ($self) = @_;

  return $self->{Creator};
}

sub ValidateValue($$$)
{
  #my ($self, $Value, $IsNew) = @_;
  return undef;
}

sub CreateDetailrefPropertyDescriptor($$$$$)
{
  my ($Name, $DisplayName, $IsKey, $IsRequired, $Creator) = @_;
  return ObjectModel::DetailrefPropertyDescriptor->new($Name, $DisplayName, $IsKey, $IsRequired, $Creator);
}

sub SetDetailrefKeyPrefix($@)
{
  my $KeyPrefix = shift;
  foreach my $PropertyDescriptor (@_)
  {
    if ($PropertyDescriptor->{IsKey})
    {
      # Defines the prefix to prepend to the field name when the key is
      # inherited by a child object through a DetailrefPropertyDescriptor
      # relation.
      $PropertyDescriptor->{KeyPrefix} = $KeyPrefix;
    }
  }
}

1;

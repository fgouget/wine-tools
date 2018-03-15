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

package ObjectModel::BasicPropertyDescriptor;

=head1 NAME

ObjectModel::BasicPropertyDescriptor - Defines a basic property

=head1 DESCRIPTION

This handles the boolean, a number and string columns.

=cut

use ObjectModel::PropertyDescriptor;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::PropertyDescriptor Exporter);
@EXPORT = qw(&CreateBasicPropertyDescriptor);

sub _initialize($$$)
{
  my ($self, $Type, $MaxLength) = @_;

  $self->{Class} = "Basic";
  $self->{Type} = $Type;
  $self->{MaxLength} = $MaxLength;

  $self->SUPER::_initialize();
}

sub GetType($)
{
  my ($self) = @_;

  return $self->{Type};
}

sub GetMaxLength($)
{
  my ($self) = @_;

  return $self->{MaxLength};
}

sub GetColNames($)
{
  my ($self) = @_;

  return [$self->{Name}];
}

sub ValidateValue($$$)
{
  my ($self, $Value, $IsNew) = @_;

  if ($self->GetIsRequired())
  {
    if (($self->GetType() ne "S" || ! $IsNew) &&
        $self->GetType() ne "B" &&
        (! defined($Value) || $Value eq ""))
    {
      return $self->GetDisplayName() .  ": Must be entered";
    }
  }

  if (! defined($Value) || $Value eq "")
  {
    return undef;
  }

  if ($self->GetType() ne "B" && $self->GetMaxLength() < length($Value))
  {
    return $self->GetDisplayName() . ": Too long";
  }

  if ($self->GetType() eq "N" && ! ($Value =~ /^\s*\d+\s*$/))
  {
    return $self->GetDisplayName() . ": Invalid number";
  }

  return undef;
}

sub CreateBasicPropertyDescriptor($$$$$$)
{
  my ($Name, $DisplayName, $IsKey, $IsRequired, $Type, $MaxLength) = @_;
  return ObjectModel::BasicPropertyDescriptor->new($Name, $DisplayName, $IsKey, $IsRequired, $Type, $MaxLength);
}

1;

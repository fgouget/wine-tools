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

package ObjectModel::BackEnd;

=head1 NAME

ObjectModel::BackEnd - Base class for data storage back ends

=head1 DESCRIPTION

See ObjectModel::DBIBackEnd for the list of methods that actual implementations
should provide.

=cut

use vars qw(@ISA @EXPORT %ActiveBackEnds);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(%ActiveBackEnds);

sub new($@)
{
  my $class = shift;

  my $self = {};
  $self = bless $self, $class;
  $self->_initialize(@_);
  return $self;
}

sub _initialize($)
{
  #my ($self) = @_;
}

1;

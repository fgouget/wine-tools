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

package WineTestBot::Role;

=head1 NAME

WineTestBot::Role - A Role item

=head1 DESCRIPTION

A Role is a class of users and defines what they can do.

=cut

use WineTestBot::WineTestBotObjects;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);


package WineTestBot::Roles;

=head1 NAME

WineTestBot::Roles - A collection of WineTestBot::Role objects

=cut

use ObjectModel::BasicPropertyDescriptor;
use WineTestBot::WineTestBotObjects;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateRoles);


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Role->new($self);
}

my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("Name", "Role name", 1,  1, "A", 20),
  CreateBasicPropertyDescriptor("IsDefaultRole", "Should new users get this role by default", !1, 1, "B", 1),
);

=pod
=over 12

=item C<CreateRoles()>

Creates a collection of Role objects.

=back
=cut

sub CreateRoles(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::Roles->new("Roles", "Roles", "Role",
                                 \@PropertyDescriptors, $ScopeObject);
}

1;

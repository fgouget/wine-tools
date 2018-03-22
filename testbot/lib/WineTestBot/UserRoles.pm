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

package WineTestBot::UserRole;

=head1 NAME

WineTestBot::UserRole - A UserRole item

=cut

use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

package WineTestBot::UserRoles;

=head1 NAME

WineTestBot::UserRoles - A collection of WineTestBot::UserRole objects

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::Roles;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateUserRoles);


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::UserRole->new($self);
}

my @PropertyDescriptors = (
  CreateItemrefPropertyDescriptor("Role", "Role", 1,  1, \&CreateRoles, ["RoleName"]),
);

=pod
=over 12

=item C<CreateUserRoles()>

Creates a collection of UserRole objects.

=back
=cut

sub CreateUserRoles(;$$)
{
  my ($ScopeObject, $User) = @_;
  return WineTestBot::UserRoles->new("UserRoles", "UserRoles", "UserRole",
                                     \@PropertyDescriptors, $ScopeObject, $User);
}

1;

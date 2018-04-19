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
our @ISA = qw(WineTestBot::WineTestBotItem);


package WineTestBot::UserRoles;

=head1 NAME

WineTestBot::UserRoles - A collection of WineTestBot::UserRole objects

=cut

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotCollection);
our @EXPORT = qw(CreateUserRoles);

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::Roles;


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::UserRole->new($self);
}

my @PropertyDescriptors = (
  CreateItemrefPropertyDescriptor("Role", "Role", 1,  1, \&CreateRoles, ["RoleName"]),
);
my @FlatPropertyDescriptors = (
  CreateBasicPropertyDescriptor("UserName", "Username",  1,  1, "A", 40),
  @PropertyDescriptors
);

=pod
=over 12

=item C<CreateUserRoles()>

When given a User object returns a collection containing the corresponding
roles. In this case the Role objects don't store the key of their parent.

If no User object is specified all the table rows are returned and the UserRole
objects have a UserName property.

=back
=cut

sub CreateUserRoles(;$$)
{
  my ($ScopeObject, $User) = @_;
  return WineTestBot::UserRoles->new("UserRoles", "UserRoles", "UserRole",
      $User ? \@PropertyDescriptors : \@FlatPropertyDescriptors,
      $ScopeObject, $User);
}

1;

# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Web session handling
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


package WineTestBot::CGI::Session;

=head1 NAME

WineTestBot::CGI::Session - A web user's session

=cut

use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotItem);

use WineTestBot::Utils;

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->SUPER::InitializeNew($Collection);

  $self->Permanent(!1);
}


package WineTestBot::CGI::Sessions;

=head1 NAME

WineTestBot::CGI::Sessions - A Session collection

=cut

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotCollection);
our @EXPORT = qw(CreateSessions DeleteSessions NewSession);

use CGI::Cookie;
use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::Users;
use WineTestBot::Utils;


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::CGI::Session->new($self);
}

my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("Id",        "Session id",         1,  1, "A", 32),
  CreateItemrefPropertyDescriptor("User",    "User",              !1,  1, \&CreateUsers, ["UserName"]),
  CreateBasicPropertyDescriptor("Permanent", "Permanent session", !1,  1, "B",  1),
);

=pod
=over 12

=item C<CreateSessions()>

Creates a collection of Session objects.

=back
=cut

sub CreateSessions(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::CGI::Sessions->new("Sessions", "Sessions", "Session",
                                         \@PropertyDescriptors, $ScopeObject);
}

sub DeleteNonPermanentSessions($)
{
  my ($User) = @_;

  my $Sessions = CreateSessions();
  $Sessions->AddFilter("User", [$User]);
  $Sessions->AddFilter("Permanent", [!1]);
  map { $Sessions->DeleteItem($_); } @{$Sessions->GetItems()};
}

sub DeleteSessions($)
{
  my ($User) = @_;

  my $Sessions = CreateSessions();
  $Sessions->AddFilter("User", [$User]);
  map { $Sessions->DeleteItem($_); } @{$Sessions->GetItems()};
}

sub NewSession($$$)
{
  my ($self, $User, $Permanent) = @_;

  DeleteNonPermanentSessions($User);

  my $Session = $self->Add();
  my $Existing = $Session;
  my $Id;
  while (defined($Existing))
  {
    $Id = "";
    foreach my $i (1..8)
    {
      $Id .= sprintf("%lx", int(rand(2 ** 16)));
    }
    $Existing = $self->GetItem($Id);
  }
  $Session->Id($Id);
  $Session->User($User);
  $Session->Permanent($Permanent);

  my ($ErrKey, $ErrProperty, $ErrMessage) = $self->Save();

  return ($ErrMessage, $Session);
}

1;

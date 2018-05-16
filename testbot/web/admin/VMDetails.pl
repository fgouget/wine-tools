# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# VM details page
#
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

package VMDetailsPage;

use ObjectModel::CGI::ItemPage;
our @ISA = qw(ObjectModel::CGI::ItemPage);

use WineTestBot::VMs;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateVMs());
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  return "" if ($PropertyName =~ /^(?:ChildPid|ChildDeadline|Errors)$/);
  return $self->SUPER::DisplayProperty($PropertyDescriptor);
}

sub Save($)
{
  my ($self) = @_;

  my $OldStatus = $self->{Item}->Status || "";
  return !1 if (!$self->SaveProperties());

  if ($OldStatus ne $self->{Item}->Status)
  {
    # The administrator action resets the consecutive error count
    $self->{Item}->Errors(undef);
    my ($ErrProperty, $ErrMessage) = $self->{Item}->Validate();
    if (!defined $ErrMessage)
    {
      $self->{Item}->RecordStatus(undef, $self->{Item}->Status ." administrator");
    }
  }

  ($self->{ErrField}, $self->{ErrMessage}) = $self->{Item}->Save();
  return ! defined($self->{ErrMessage});
}


package main;

my $Request = shift;

my $VMDetailsPage = VMDetailsPage->new($Request, "admin");
$VMDetailsPage->GeneratePage();

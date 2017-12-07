# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014 Francois Gouget
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

package ObjectModel::Collection;

=head1 NAME

ObjectModel::Collection - Base class for item collections

=head1 DESCRIPTION

Provides a set of methods to manipulate a collection of objects, and in
particular load and save them to a database table using ObjectModel::BackEnd.
Also provides a set of filtering methods to specify the set of objects we are
interested in so only those objects are retrieved from the database.

Note that there may be multiple collections corresponding to a given table at
the same time. This is how one retrieves the objects based on different
criteria.

=cut

use vars qw(@ISA @EXPORT_OK);

require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(&new &ComputeMasterKey);

use ObjectModel::BackEnd;
use ObjectModel::Item;
use ObjectModel::PropertyDescriptor;


sub ComputeMasterKey($)
{
  my ($MasterColValues) = @_;

  my $MasterKey = "";
  if (defined $MasterColValues)
  {
    foreach my $ColValue (@$MasterColValues)
    {
      return undef if (!defined $ColValue);
      $MasterKey .= "$ColValue#@#";
    }
  }
  return $MasterKey;
}

sub new($$$$$;$$@)
{
  my $class = shift;
  my $TableName = shift;
  my $CollectionName = shift;
  my $ItemName = shift;
  my $PropertyDescriptors = shift;
  my $ScopeObject = shift;
  my ($MasterObject) = @_;

  my $MasterKey = "";
  my ($AllScopeItems, $MasterColNames, $MasterColValues);
  if (defined $MasterObject)
  {
    $AllScopeItems = $MasterObject->{AllScopeItems};
    ($MasterColNames, $MasterColValues) = $MasterObject->GetMasterKey();
  }
  if (defined $ScopeObject)
  {
    $AllScopeItems ||= $ScopeObject->{AllScopeItems};
  }

  my $self = {TableName           => $TableName,
              CollectionName      => $CollectionName,
              ItemName            => $ItemName,
              PropertyDescriptors => $PropertyDescriptors,
              MasterColNames      => $MasterColNames,
              MasterColValues     => $MasterColValues,
              MasterKey           => ComputeMasterKey($MasterColValues),
              Filters             => {},
              AllScopeItems       => $AllScopeItems || {},
              Items               => undef};
  $self = bless $self, $class;
  $self->_initialize(@_);
  return $self;
}

sub _initialize($;$)
{
  # $MasterObject may be required for some Collections.
  my ($self, $_MasterObject) = @_;

  $self->{AllScopeItems}->{ref($self)} ||= {};
}

sub GetPropertyDescriptors($)
{
  my ($self) = @_;

  return $self->{PropertyDescriptors};
}

sub GetPropertyDescriptorByName($$)
{
  my ($self, $Name) = @_;

  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    if ($PropertyDescriptor->GetName() eq $Name)
    {
      return $PropertyDescriptor;
    }
  }

  return undef;
}

sub GetTableName($)
{
  my ($self) = @_;

  return $self->{TableName};
}

sub GetCollectionName($)
{
  my ($self) = @_;

  return $self->{CollectionName};
}

sub GetItemName($)
{
  my ($self) = @_;

  return $self->{ItemName};
}

sub Load($)
{
  my ($self) = @_;

  $self->GetBackEnd()->LoadCollection($self);

  $self->{Loaded} = 1;
}

=pod
=over 12

=item C<Add()>

Instantiates a new Item and adds it to the Collection.

Note that not only does calling Add() not force loading from the database,
it marks the Collection as loaded. So if Add() is the first call on a
Collection, calling GetKeys() or GetItems() later on will only return the new
Item.

See Item->new() for details on the Item's default column values and for
important information regarding its primary key.

=back
=cut

sub Add($)
{
  my ($self) = @_;

  my $NewItem = $self->CreateItem();
  $NewItem->InitializeNew($self);
  my $Key = $NewItem->GetKey();
  $self->{Items}{$Key} = $NewItem;

  my $FullKey = $self->GetFullKey($Key);
  if (defined $FullKey)
  {
    my $ScopeItems = $self->{AllScopeItems}->{ref($self)};
    $ScopeItems->{$FullKey} = $NewItem;
  }
  # If the Item does not yet have a full key, then it will be added to
  # AllScopeItems when Item::MasterKeyChanged() is called.

  $self->{Loaded} = 1;

  return $NewItem;
}

sub GetKeysNoLoad($)
{
  my ($self) = @_;

  my @Keys = keys %{$self->{Items}};
  return \@Keys;
}

sub GetKeys($)
{
  my ($self) = @_;

  if (! $self->{Loaded})
  {
    $self->Load();
  }

  return $self->GetKeysNoLoad();
}

=pod
=over 12

=item C<GetFullKey()>

Turns a string that uniquely identifies an Item object for the current
Collection into a string that uniquely identifies across all Collections of
the same type.

For instance a TaskNo uniquely identifies a Task within the corresponding
Step->Tasks collection. However only a string derived from the
(JobId, StepNo, TaskNo) triplet uniquely identifies it across all Tasks
collections.

=back
=cut

sub GetFullKey($$)
{
  my ($self, $Key) = @_;

  return undef if (!defined $self->{MasterKey});
  return $self->{MasterKey} . $Key;
}

=pod
=over 12

=item C<GetScopeItem()>

Returns the Item object for the specified key if it is already present in the
current scope cache. If not present in the scope cache but an item object was
given as a parameter, then that Item is added to the scope cache and that
Item is returned.

=back
=cut

sub GetScopeItem($$$)
{
  my ($self, $Key, $NewItem) = @_;

  my $FullKey = $self->GetFullKey($Key);
  return $NewItem if (!defined $FullKey);

  my $ScopeItems = $self->{AllScopeItems}->{ref($self)};
  my $Item = $ScopeItems->{$FullKey};
  return $Item if (defined $Item);
  return undef if (!defined $NewItem);

  $ScopeItems->{$FullKey} = $NewItem;
  return $NewItem;
}

=pod
=over 12

=item C<GetItem()>

Loads the specified Item and adds it to the Collection. Note that the Item
gets loaded and added even if it does not match the Collection's filters.

=back
=cut

sub GetItem($$)
{
  my ($self, $Key) = @_;

  return undef if (!defined $Key);
  return $self->{Items}{$Key} if (defined $self->{Items}{$Key});

  # The Item is not present in this Collection.
  # See if another in-scope Collection loaded it already.
  my ($ScopeItems, $Item);
  my $FullKey = $self->GetFullKey($Key);
  if (defined $FullKey)
  {
    $ScopeItems = $self->{AllScopeItems}->{ref($self)};
    $Item = $ScopeItems->{$FullKey};
  }
  if (!defined $Item)
  {
    # Still not found so try to load it from the database.
    $Item = $self->GetBackEnd()->LoadItem($self, $Key);
    return undef if (!defined $Item);
    $ScopeItems->{$FullKey} = $Item if ($ScopeItems);
  }

  # Add the Item to this Collection.
  $self->{Items}{$Key} = $Item;
  return $Item;
}

=pod
=over 12

=item C<ItemExists()>

Returns true if the specified item is present in the collection, that is if it
either matches the specified filter, or has been explicitly loaded through
GetItem().

=back
=cut

sub ItemExists($$)
{
  my ($self, $Key) = @_;

  if (! defined($Key))
  {
    return !1;
  }

  if (! $self->{Loaded})
  {
    $self->Load();
  }

  return exists($self->{Items}{$Key});
}

=pod
=over 12

=item C<GetItems()>

Returns all the Item objects present in the Collection, that is all the objects
that either match the Collection's filter, or have been explicitly loaded
through GetItem().

=back
=cut

sub GetItems($)
{
  my ($self) = @_;

  if (! $self->{Loaded})
  {
    $self->Load();
  }

  my @Items = values %{$self->{Items}};
  return \@Items;
}

=pod
=over 12

=item C<IsEmpty()>

Returns true if the Collection contains no Item.

=back
=cut

sub IsEmpty($)
{
  my ($self) = @_;

  if (! $self->{Loaded})
  {
    $self->Load();
  }

  return scalar(keys %{$self->{Items}}) == 0;
}

sub CombineKey($@)
{
  my $self = shift;

  my $CombinedKey = join("#@#", @_);
  return $CombinedKey;
}

sub SplitKey($$)
{
  my ($self, $CombinedKey) = @_;

  my @KeyComponents = split /#@#/, $CombinedKey;

  return @KeyComponents;
}

=pod
=over 12

=item C<Validate()>

Validates all the new and modified Item objects present in the Collection.

In case of an error this returns a triplet containing the invalid Item's key,
the invalid property name and the error message. The property name may be undef
if no specific property is invalid.

If no Item is invalid then (undef, undef, undef) is returned.

=back
=cut

sub Validate($)
{
  my ($self) = @_;

  foreach my $Item (values %{$self->{Items}})
  {
    if ($Item->GetIsNew() || $Item->GetIsModified())
    {
      (my $ErrProperty, my $ErrMessage) = $Item->Validate();
      if (defined($ErrMessage))
      {
        return ($Item->GetKey(), $ErrProperty, "$ErrMessage for " .
                $self->GetItemName() . " " . $Item->GetFullKey());
      }
      if ($Item->GetIsNew())
      {
        my $HasSequenceKey = !1;
        foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
        {
          if ($PropertyDescriptor->GetIsKey() &&
              $PropertyDescriptor->GetClass() eq "Basic" &&
              $PropertyDescriptor->GetType() eq "S")
          {
            $HasSequenceKey = 1;
            last;
          }
        }
        if (! $HasSequenceKey)
        {
          my $ExistingItem = $self->GetBackEnd()->LoadItem($self, $Item->GetKey());
          if (defined($ExistingItem))
          {
            $ErrMessage = $self->GetItemName() . " " . $Item->GetFullKey() .
                          " already exists";
            return ($Item->GetKey(), undef, $ErrMessage);
          }
        }
      }
    }
  }

  return (undef, undef, undef);
}

sub SaveNoValidate($)
{
  my ($self) = @_;

  $self->GetBackEnd()->SaveCollection($self);

  foreach my $PropertyDescriptor (@{$self->GetPropertyDescriptors()})
  {
    if ($PropertyDescriptor->GetClass() eq "Detailref")
    {
      foreach my $Item (values %{$self->{Items}})
      {
        my $Detail = $Item->{Details}{$PropertyDescriptor->GetName()};
        if (defined($Detail))
        {
          $Detail->SaveNoValidate();
        }
      }
    }
  }
}

sub Save($)
{
  my ($self) = @_;

  my ($ErrKey, $ErrProperty, $ErrMessage) = $self->Validate();
  if (! defined($ErrMessage))
  {
    $self->SaveNoValidate();
  }


  return ($ErrKey, $ErrProperty, $ErrMessage);
}

sub KeyChanged($$$)
{
  my ($self, $OldKey, $NewKey) = @_;

  my $Item = $self->{Items}{$OldKey};
  if (! defined($Item))
  {
    die "Can't change key from $OldKey to $NewKey";
  }
  my $ScopeItems = $self->{AllScopeItems}->{ref($self)};
  my $FullKey = $self->GetFullKey($OldKey);
  delete $ScopeItems->{$FullKey} if (defined $FullKey);
  delete $self->{Items}{$OldKey};

  if (defined($self->{Items}{$NewKey}))
  {
    die "Could not change key, new key $NewKey already exists";
  }
  $FullKey = $self->GetFullKey($NewKey);
  $ScopeItems->{$FullKey} = $Item if (defined $FullKey);
  $self->{Items}{$NewKey} = $Item;

  $Item->KeyChanged();
}

sub MasterKeyChanged($$)
{
  my ($self, $MasterColValues) = @_;

  $self->{MasterColValues} = $MasterColValues;
  $self->{MasterKey} = ComputeMasterKey($MasterColValues);

  foreach my $Item (values %{$self->{Items}})
  {
    $Item->MasterKeyChanged($MasterColValues);
  }
}

sub GetMasterCols($)
{
  my ($self) = @_;

  return ($self->{MasterColNames}, $self->{MasterColValues});
}

=pod
=over 12

=item C<DeleteItem()>

Deletes the specified Item from the Collection and the database backing it.

Note that if there are other tables with a foreign key referencing this item
the corresponding rows will be deleted too. So for instance deleting a Job
will also delete the Steps and Tasks it is composed of.

=back
=cut

sub DeleteItem($$)
{
  my ($self, $Item) = @_;

  my $ErrMessage = $Item->OnDelete();
  if (defined($ErrMessage))
  {
    return $ErrMessage;
  }
  my $Key = $Item->GetKey();
  $ErrMessage = $self->GetBackEnd()->DeleteItem($Item);
  if (defined($ErrMessage))
  {
    return $ErrMessage;
  }

  my $FullKey = $self->GetFullKey($Key);
  if (defined $FullKey)
  {
    my $ScopeItems = $self->{AllScopeItems}->{ref($self)};
    delete($ScopeItems->{$FullKey})
  }
  delete($self->{Items}{$Key});

  return undef;
}

sub DeleteAll($)
{
  my ($self) = @_;

  if (! $self->{Loaded})
  {
    $self->Load();
  }
  foreach my $Item (values %{$self->{Items}})
  {
    my $ErrMessage = $Item->OnDelete();
    if (defined($ErrMessage))
    {
      return $ErrMessage;
    }
  }

  my $ErrMessage = $self->GetBackEnd()->DeleteAll($self);
  if (defined($ErrMessage))
  {
    return $ErrMessage;
  }

  my $ScopeItems = $self->{AllScopeItems}->{ref($self)};
  foreach my $Key (keys %{$self->{Items}})
  {
    my $FullKey = $self->GetFullKey($Key);
    delete($ScopeItems->{$FullKey}) if (defined $FullKey);
    delete($self->{Items}{$Key});
  }

  return undef;
}

sub AddFilter($$$)
{
  my ($self, $PropertyName, $Value) = @_;

  $self->{Filters}{$PropertyName} = $Value;
}

sub GetFilters($)
{
  my ($self) = @_;

  return $self->{Filters};
}

1;

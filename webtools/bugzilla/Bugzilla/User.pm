# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla Bug Tracking System.
#
# The Initial Developer of the Original Code is Netscape Communications
# Corporation. Portions created by Netscape are
# Copyright (C) 1998 Netscape Communications Corporation. All
# Rights Reserved.
#
# Contributor(s): Myk Melez <myk@mozilla.org>
#                 Erik Stambaugh <erik@dasbistro.com>
#                 Bradley Baetz <bbaetz@acm.org>
#                 Joel Peshkin <bugreport@peshkin.net> 
#                 Byron Jones <bugzilla@glob.com.au>
#                 Max Kanat-Alexander <mkanat@kerio.com>

################################################################################
# Module Initialization
################################################################################

# Make it harder for us to do dangerous things in Perl.
use strict;

# This module implements utilities for dealing with Bugzilla users.
package Bugzilla::User;

use Bugzilla::Config;
use Bugzilla::Error;
use Bugzilla::Util;
use Bugzilla::Constants;
use Bugzilla::Auth;

use base qw(Exporter);
@Bugzilla::User::EXPORT = qw(insert_new_user is_available_username
    login_to_id
);

################################################################################
# Functions
################################################################################

sub new {
    my $invocant = shift;
    if (scalar @_ == 0) {
        return $invocant->_create;
    }
    return $invocant->_create("userid=?", @_);
}

# This routine is sort of evil. Nothing except the login stuff should
# be dealing with addresses as an input, and they can get the id as a
# side effect of the other sql they have to do anyway.
# Bugzilla::BugMail still does this, probably as a left over from the
# pre-id days. Provide this as a helper, but don't document it, and hope
# that it can go away.
# The request flag stuff also does this, but it really should be passing
# in the id its already had to validate (or the User.pm object, of course)
sub new_from_login {
    my $invocant = shift;
    return $invocant->_create("login_name=?", @_);
}

# Internal helper for the above |new| methods
# $cond is a string (including a placeholder ?) for the search
# requirement for the profiles table
sub _create {
    my $invocant = shift;
    my $class = ref($invocant) || $invocant;

    my $cond = shift;
    my $val = shift;

    # Allow invocation with no parameters to create a blank object
    my $self = {
        'id'             => 0,
        'name'           => '',
        'login'          => '',
        'showmybugslink' => 0,
        'flags'          => {},
    };
    bless ($self, $class);
    return $self unless $cond && $val;

    # We're checking for validity here, so any value is OK
    trick_taint($val);

    my $tables_locked_for_derive_groups = shift;

    my $dbh = Bugzilla->dbh;

    my ($id,
        $login,
        $name,
        $mybugslink) = $dbh->selectrow_array(qq{SELECT userid,
                                                       login_name,
                                                       realname,
                                                       mybugslink
                                                  FROM profiles
                                                 WHERE $cond},
                                             undef,
                                             $val);

    return undef unless defined $id;

    $self->{'id'}             = $id;
    $self->{'name'}           = $name;
    $self->{'login'}          = $login;
    $self->{'showmybugslink'} = $mybugslink;

    # Now update any old group information if needed
    my $result = $dbh->selectrow_array(q{SELECT 1
                                           FROM profiles, groups
                                          WHERE userid=?
                                            AND profiles.refreshed_when <=
                                                  groups.last_changed},
                                       undef,
                                       $id);

    if ($result) {
        my $is_main_db;
        unless ($is_main_db = Bugzilla->dbwritesallowed()) {
            Bugzilla->switch_to_main_db();
        }
        $self->derive_groups($tables_locked_for_derive_groups);
        unless ($is_main_db) {
            Bugzilla->switch_to_shadow_db();
        }
    }

    return $self;
}

# Accessors for user attributes
sub id { $_[0]->{id}; }
sub login { $_[0]->{login}; }
sub email { $_[0]->{login} . Param('emailsuffix'); }
sub name { $_[0]->{name}; }
sub showmybugslink { $_[0]->{showmybugslink}; }

sub set_flags {
    my $self = shift;
    while (my $key = shift) {
        $self->{'flags'}->{$key} = shift;
    }
}

sub get_flag {
    my $self = shift;
    my $key = shift;
    return $self->{'flags'}->{$key};
}

# Generate a string to identify the user by name + login if the user
# has a name or by login only if she doesn't.
sub identity {
    my $self = shift;

    return "" unless $self->id;

    if (!defined $self->{identity}) {
        $self->{identity} = 
          $self->{name} ? "$self->{name} <$self->{login}>" : $self->{login};
    }

    return $self->{identity};
}

sub nick {
    my $self = shift;

    return "" unless $self->id;

    if (!defined $self->{nick}) {
        $self->{nick} = (split(/@/, $self->{login}, 2))[0];
    }

    return $self->{nick};
}

sub queries {
    my $self = shift;

    return $self->{queries} if defined $self->{queries};
    return [] unless $self->id;

    my $dbh = Bugzilla->dbh;
    my $sth = $dbh->prepare(q{ SELECT
                             DISTINCT name, query, linkinfooter,
                                      IF(whine_queries.id IS NOT NULL, 1, 0)
                                 FROM namedqueries
                            LEFT JOIN whine_queries
                                   ON whine_queries.query_name = name
                                WHERE userid=?
                             ORDER BY UPPER(name)});
    $sth->execute($self->{id});

    my @queries;
    while (my $row = $sth->fetch) {
        push (@queries, {
                          name         => $row->[0],
                          query        => $row->[1],
                          linkinfooter => $row->[2],
                          usedinwhine  => $row->[3],
                        });
    }
    $self->{queries} = \@queries;

    return $self->{queries};
}

sub flush_queries_cache {
    my $self = shift;

    delete $self->{queries};
}

sub groups {
    my $self = shift;

    return $self->{groups} if defined $self->{groups};
    return {} unless $self->id;

    my $dbh = Bugzilla->dbh;
    my $groups = $dbh->selectcol_arrayref(q{SELECT DISTINCT groups.name, group_id
                                              FROM groups, user_group_map
                                             WHERE groups.id=user_group_map.group_id
                                               AND user_id=?
                                               AND isbless=0},
                                          { Columns=>[1,2] },
                                          $self->{id});

    # The above gives us an arrayref [name, id, name, id, ...]
    # Convert that into a hashref
    my %groups = @$groups;
    $self->{groups} = \%groups;

    return $self->{groups};
}

sub in_group {
    my ($self, $group) = @_;

    # If we already have the info, just return it.
    return defined($self->{groups}->{$group}) if defined $self->{groups};
    return 0 unless $self->id;

    # Otherwise, go check for it

    my $dbh = Bugzilla->dbh;

    my ($res) = $dbh->selectrow_array(q{SELECT 1
                                  FROM groups, user_group_map
                                 WHERE groups.id=user_group_map.group_id
                                   AND user_group_map.user_id=?
                                   AND isbless=0
                                   AND groups.name=?},
                              undef,
                              $self->id,
                              $group);

    return defined($res);
}

sub can_see_bug {
    my ($self, $bugid) = @_;
    my $dbh = Bugzilla->dbh;
    my $sth  = $self->{sthCanSeeBug};
    my $userid  = $self->{id};
    # Get fields from bug, presence of user on cclist, and determine if
    # the user is missing any groups required by the bug. The prepared query
    # is cached because this may be called for every row in buglists or
    # every bug in a dependency list.
    unless ($sth) {
        $sth = $dbh->prepare("SELECT reporter, assigned_to, qa_contact,
                             reporter_accessible, cclist_accessible,
                             COUNT(cc.who), COUNT(bug_group_map.bug_id)
                             FROM bugs
                             LEFT JOIN cc 
                               ON cc.bug_id = bugs.bug_id
                               AND cc.who = $userid
                             LEFT JOIN bug_group_map 
                               ON bugs.bug_id = bug_group_map.bug_id
                               AND bug_group_map.group_ID NOT IN(" .
                               join(',',(-1, values(%{$self->groups}))) .
                               ") WHERE bugs.bug_id = ? GROUP BY bugs.bug_id");
    }
    $sth->execute($bugid);
    my ($reporter, $owner, $qacontact, $reporter_access, $cclist_access,
        $isoncclist, $missinggroup) = $sth->fetchrow_array();
    $sth->finish;
    $self->{sthCanSeeBug} = $sth;
    return ( (($reporter == $userid) && $reporter_access)
           || (Param('useqacontact') && ($qacontact == $userid) && $userid)
           || ($owner == $userid)
           || ($isoncclist && $cclist_access)
           || (!$missinggroup) );
}

sub get_selectable_products {
    my ($self, $by_id) = @_;

    if (defined $self->{SelectableProducts}) {
        my %list = @{$self->{SelectableProducts}};
        return \%list if $by_id;
        return values(%list);
    }

    my $query = "SELECT id, name " .
                "FROM products " .
                "LEFT JOIN group_control_map " .
                "ON group_control_map.product_id = products.id ";
    if (Param('useentrygroupdefault')) {
        $query .= "AND group_control_map.entry != 0 ";
    } else {
        $query .= "AND group_control_map.membercontrol = " .
                  CONTROLMAPMANDATORY . " ";
    }
    $query .= "AND group_id NOT IN(" . 
               join(',', (-1,values(%{Bugzilla->user->groups}))) . ") " .
              "WHERE group_id IS NULL ORDER BY name";
    my $dbh = Bugzilla->dbh;
    my $sth = $dbh->prepare($query);
    $sth->execute();
    my @products = ();
    while (my @row = $sth->fetchrow_array) {
        push(@products, @row);
    }
    $self->{SelectableProducts} = \@products;
    my %list = @products;
    return \%list if $by_id;
    return values(%list);
}

# visible_groups_inherited returns a reference to a list of all the groups
# whose members are visible to this user.
sub visible_groups_inherited {
    my $self = shift;
    return $self->{visible_groups_inherited} if defined $self->{visible_groups_inherited};
    return [] unless $self->id;
    my @visgroups = @{$self->visible_groups_direct};
    @visgroups = @{$self->flatten_group_membership(@visgroups)};
    $self->{visible_groups_inherited} = \@visgroups;
    return $self->{visible_groups_inherited};
}

# visible_groups_direct returns a reference to a list of all the groups that
# are visible to this user.
sub visible_groups_direct {
    my $self = shift;
    my @visgroups = ();
    return $self->{visible_groups_direct} if defined $self->{visible_groups_direct};
    return [] unless $self->id;

    my $dbh = Bugzilla->dbh;
    my $glist = join(',',(-1,values(%{$self->groups})));
    my $sth = $dbh->prepare("SELECT DISTINCT grantor_id
                                FROM group_group_map
                               WHERE member_id IN($glist)
                                 AND grant_type=" . GROUP_VISIBLE);
    $sth->execute();

    while (my ($row) = $sth->fetchrow_array) {
        push @visgroups,$row;
    }
    $self->{visible_groups_direct} = \@visgroups;

    return $self->{visible_groups_direct};
}

sub derive_groups {
    my ($self, $already_locked) = @_;

    my $id = $self->id;
    return unless $id;

    my $dbh = Bugzilla->dbh;

    my $sth;

    $dbh->bz_lock_tables('profiles WRITE', 'user_group_map WRITE',
                         'group_group_map READ',
                         'groups READ') unless $already_locked;

    # avoid races, we are only up to date as of the BEGINNING of this process
    my $time = $dbh->selectrow_array("SELECT NOW()");

    # first remove any old derived stuff for this user
    $dbh->do(q{DELETE FROM user_group_map
                      WHERE user_id = ?
                        AND grant_type != ?},
             undef,
             $id,
             GRANT_DIRECT);

    my %groupidsadded = ();
    # add derived records for any matching regexps

    $sth = $dbh->prepare("SELECT id, userregexp FROM groups WHERE userregexp != ''");
    $sth->execute;

    my $group_insert;
    while (my $row = $sth->fetch) {
        if ($self->{login} =~ m/$row->[1]/i) {
            $group_insert ||= $dbh->prepare(q{INSERT INTO user_group_map
                                              (user_id, group_id, isbless, grant_type)
                                              VALUES (?, ?, 0, ?)});
            $groupidsadded{$row->[0]} = 1;
            $group_insert->execute($id, $row->[0], GRANT_REGEXP);
        }
    }

    # Get a list of the groups of which the user is a member.
    my %groupidschecked = ();

    my @groupidstocheck = @{$dbh->selectcol_arrayref(q{SELECT group_id
                                                         FROM user_group_map
                                                        WHERE user_id=?},
                                                     undef,
                                                     $id)};

    # Each group needs to be checked for inherited memberships once.
    my $group_sth;
    while (@groupidstocheck) {
        my $group = shift @groupidstocheck;
        if (!defined($groupidschecked{"$group"})) {
            $groupidschecked{"$group"} = 1;
            $group_sth ||= $dbh->prepare(q{SELECT grantor_id
                                             FROM group_group_map
                                            WHERE member_id=?
                                              AND grant_type=' . 
                                                  GROUP_MEMBERSHIP . '});
            $group_sth->execute($group);
            while (my ($groupid) = $group_sth->fetchrow_array) {
                if (!defined($groupidschecked{"$groupid"})) {
                    push(@groupidstocheck,$groupid);
                }
                if (!$groupidsadded{$groupid}) {
                    $groupidsadded{$groupid} = 1;
                    $group_insert ||= $dbh->prepare(q{INSERT INTO user_group_map
                                                      (user_id, group_id, isbless, grant_type)
                                                      VALUES (?, ?, 0, ?)});
                    $group_insert->execute($id, $groupid, GRANT_DERIVED);
                }
            }
        }
    }

    $dbh->do(q{UPDATE profiles
                  SET refreshed_when = ?
                WHERE userid=?},
             undef,
             $time,
             $id);
    $dbh->bz_unlock_tables() unless $already_locked;
}

sub can_bless {
    my $self = shift;

    return $self->{can_bless} if defined $self->{can_bless};
    return 0 unless $self->id;

    my $dbh = Bugzilla->dbh;
    # First check if the user can explicitly bless a group
    my $res = $dbh->selectrow_arrayref(q{SELECT 1
                                           FROM user_group_map
                                          WHERE user_id=?
                                            AND isbless=1},
                                       undef,
                                       $self->{id});
    if (!$res) {
        # Now check if user is a member of a group that can bless a group
        $res = $dbh->selectrow_arrayref(q{SELECT 1
                                            FROM user_group_map, group_group_map
                                           WHERE user_group_map.user_id=?
                                             AND user_group_map.group_id=member_id
                                             AND group_group_map.grant_type=} .
                                                 GROUP_BLESS,
                                        undef,
                                        $self->{id});
    }

    $self->{can_bless} = $res ? 1 : 0;

    return $self->{can_bless};
}

sub flatten_group_membership {
    my ($self, @groups) = @_;

    my $dbh = Bugzilla->dbh;
    my $sth;
    my @groupidstocheck = @groups;
    my %groupidschecked = ();
    $sth = $dbh->prepare("SELECT member_id FROM group_group_map
                             WHERE grantor_id = ? 
                               AND grant_type = " . GROUP_MEMBERSHIP);
    while (my $node = shift @groupidstocheck) {
        $sth->execute($node);
        my $member;
        while (($member) = $sth->fetchrow_array) {
            if (!$groupidschecked{$member}) {
                $groupidschecked{$member} = 1;
                push @groupidstocheck, $member;
                push @groups, $member unless grep $_ == $member, @groups;
            }
        }
    }
    return \@groups;
}

sub match {
    # Generates a list of users whose login name (email address) or real name
    # matches a substring or wildcard.
    # This is also called if matches are disabled (for error checking), but
    # in this case only the exact match code will end up running.

    # $str contains the string to match, while $limit contains the
    # maximum number of records to retrieve.
    my ($str, $limit, $exclude_disabled) = @_;
    
    my @users = ();

    return \@users if $str =~ /^\s*$/;

    # The search order is wildcards, then exact match, then substring search.
    # Wildcard matching is skipped if there is no '*', and exact matches will
    # not (?) have a '*' in them.  If any search comes up with something, the
    # ones following it will not execute.

    # first try wildcards

    my $wildstr = $str;
    my $user = Bugzilla->user;
    my $dbh = Bugzilla->dbh;

    if ($wildstr =~ s/\*/\%/g && # don't do wildcards if no '*' in the string
        Param('usermatchmode') ne 'off') { # or if we only want exact matches

        # Build the query.
        my $sqlstr = &::SqlQuote($wildstr);
        my $query  = "SELECT DISTINCT userid, realname, login_name " .
                     "FROM profiles ";
        if (&::Param('usevisibilitygroups')) {
            $query .= ", user_group_map ";
        }
        $query    .= "WHERE (login_name LIKE $sqlstr " .
                     "OR realname LIKE $sqlstr) ";
        if (&::Param('usevisibilitygroups')) {
            $query .= "AND user_group_map.user_id = userid " .
                      "AND isbless = 0 " .
                      "AND group_id IN(" .
                      join(', ', (-1, @{$user->visible_groups_inherited})) . ") " .
                      "AND grant_type <> " . GRANT_DERIVED;
        }
        $query    .= " AND disabledtext = '' " if $exclude_disabled;
        $query    .= "ORDER BY length(login_name) ";
        $query    .= $dbh->sql_limit($limit) if $limit;

        # Execute the query, retrieve the results, and make them into
        # User objects.

        &::PushGlobalSQLState();
        &::SendSQL($query);
        push(@users, new Bugzilla::User(&::FetchSQLData())) while &::MoreSQLData();
        &::PopGlobalSQLState();

    }
    else {    # try an exact match

        my $sqlstr = &::SqlQuote($str);
        my $query  = "SELECT userid, realname, login_name " .
                     "FROM profiles " .
                     "WHERE login_name = $sqlstr ";
        # Exact matches don't care if a user is disabled.

        &::PushGlobalSQLState();
        &::SendSQL($query);
        push(@users, new Bugzilla::User(&::FetchSQLData())) if &::MoreSQLData();
        &::PopGlobalSQLState();
    }

    # then try substring search

    if ((scalar(@users) == 0)
        && (&::Param('usermatchmode') eq 'search')
        && (length($str) >= 3))
    {

        my $sqlstr = &::SqlQuote(uc($str));

        my $query  = "SELECT DISTINCT userid, realname, login_name " .
                     "FROM  profiles ";
        if (&::Param('usevisibilitygroups')) {
            $query .= ", user_group_map ";
        }
        $query     .= "WHERE  (INSTR(UPPER(login_name), $sqlstr) " .
                      "OR INSTR(UPPER(realname), $sqlstr)) ";
        if (&::Param('usevisibilitygroups')) {
            $query .= "AND user_group_map.user_id = userid " .
                      "AND isbless = 0 " .
                      "AND group_id IN(" .
                      join(', ', (-1, @{$user->visible_groups_inherited})) . ") " .
                      "AND grant_type <> " . GRANT_DERIVED;
        }
        $query    .= " AND disabledtext = '' " if $exclude_disabled;
        $query    .= "ORDER BY length(login_name) ";
        $query    .= $dbh->sql_limit($limit) if $limit;
        &::PushGlobalSQLState();
        &::SendSQL($query);
        push(@users, new Bugzilla::User(&::FetchSQLData())) while &::MoreSQLData();
        &::PopGlobalSQLState();
    }

    # order @users by alpha

    @users = sort { uc($a->login) cmp uc($b->login) } @users;

    return \@users;
}

# match_field() is a CGI wrapper for the match() function.
#
# Here's what it does:
#
# 1. Accepts a list of fields along with whether they may take multiple values
# 2. Takes the values of those fields from $::FORM and passes them to match()
# 3. Checks the results of the match and displays confirmation or failure
#    messages as appropriate.
#
# The confirmation screen functions the same way as verify-new-product and
# confirm-duplicate, by rolling all of the state information into a
# form which is passed back, but in this case the searched fields are
# replaced with the search results.
#
# The act of displaying the confirmation or failure messages means it must
# throw a template and terminate.  When confirmation is sent, all of the
# searchable fields have been replaced by exact fields and the calling script
# is executed as normal.
#
# match_field must be called early in a script, before anything external is
# done with the form data.
#
# In order to do a simple match without dealing with templates, confirmation,
# or globals, simply calling Bugzilla::User::match instead will be
# sufficient.

# How to call it:
#
# Bugzilla::User::match_field ({
#   'field_name'    => { 'type' => fieldtype },
#   'field_name2'   => { 'type' => fieldtype },
#   [...]
# });
#
# fieldtype can be either 'single' or 'multi'.
#

sub match_field {

    my $fields         = shift;   # arguments as a hash
    my $matches      = {};      # the values sent to the template
    my $matchsuccess = 1;       # did the match fail?
    my $need_confirm = 0;       # whether to display confirmation screen

    # prepare default form values

    my $vars = $::vars;
    $vars->{'form'}  = \%::FORM;
    $vars->{'mform'} = \%::MFORM;

    # What does a "--do_not_change--" field look like (if any)?
    my $dontchange = $vars->{'form'}->{'dontchange'};

    # Fields can be regular expressions matching multiple form fields
    # (f.e. "requestee-(\d+)"), so expand each non-literal field
    # into the list of form fields it matches.
    my $expanded_fields = {};
    foreach my $field_pattern (keys %{$fields}) {
        # Check if the field has any non-word characters.  Only those fields
        # can be regular expressions, so don't expand the field if it doesn't
        # have any of those characters.
        if ($field_pattern =~ /^\w+$/) {
            $expanded_fields->{$field_pattern} = $fields->{$field_pattern};
        }
        else {
            my @field_names = grep(/$field_pattern/, keys %{$vars->{'form'}});
            foreach my $field_name (@field_names) {
                $expanded_fields->{$field_name} = 
                  { type => $fields->{$field_pattern}->{'type'} };
                
                # The field is a requestee field; in order for its name 
                # to show up correctly on the confirmation page, we need 
                # to find out the name of its flag type.
                if ($field_name =~ /^requestee-(\d+)$/) {
                    my $flag = Bugzilla::Flag::get($1);
                    $expanded_fields->{$field_name}->{'flag_type'} = 
                      $flag->{'type'};
                }
                elsif ($field_name =~ /^requestee_type-(\d+)$/) {
                    $expanded_fields->{$field_name}->{'flag_type'} = 
                      Bugzilla::FlagType::get($1);
                }
            }
        }
    }
    $fields = $expanded_fields;

    for my $field (keys %{$fields}) {

        # Tolerate fields that do not exist.
        #
        # This is so that fields like qa_contact can be specified in the code
        # and it won't break if $::MFORM does not define them.
        #
        # It has the side-effect that if a bad field name is passed it will be
        # quietly ignored rather than raising a code error.

        next if !defined($vars->{'mform'}->{$field});

        # Skip it if this is a --do_not_change-- field
        next if $dontchange && $dontchange eq $vars->{'form'}->{$field};

        # We need to move the query to $raw_field, where it will be split up,
        # modified by the search, and put back into $::FORM and $::MFORM
        # incrementally.

        my $raw_field = join(" ", @{$vars->{'mform'}->{$field}});
        $vars->{'form'}->{$field}  = '';
        $vars->{'mform'}->{$field} = [];

        my @queries = ();

        # Now we either split $raw_field by spaces/commas and put the list
        # into @queries, or in the case of fields which only accept single
        # entries, we simply use the verbatim text.

        $raw_field =~ s/^\s+|\s+$//sg;  # trim leading/trailing space

        # single field
        if ($fields->{$field}->{'type'} eq 'single') {
            @queries = ($raw_field) unless $raw_field =~ /^\s*$/;

        # multi-field
        }
        elsif ($fields->{$field}->{'type'} eq 'multi') {
            @queries =  split(/[\s,]+/, $raw_field);

        }
        else {
            # bad argument
            ThrowCodeError('bad_arg',
                           { argument => $fields->{$field}->{'type'},
                             function =>  'Bugzilla::User::match_field',
                           });
        }

        my $limit = 0;
        if (&::Param('maxusermatches')) {
            $limit = &::Param('maxusermatches') + 1;
        }

        for my $query (@queries) {

            my $users = match(
                $query,   # match string
                $limit,   # match limit
                1         # exclude_disabled
            );

            # skip confirmation for exact matches
            if ((scalar(@{$users}) == 1)
                && (@{$users}[0]->{'login'} eq $query))
            {
                # delimit with spaces if necessary
                if ($vars->{'form'}->{$field}) {
                    $vars->{'form'}->{$field} .= " ";
                }
                $vars->{'form'}->{$field} .= @{$users}[0]->{'login'};
                push @{$vars->{'mform'}->{$field}}, @{$users}[0]->{'login'};
                next;
            }

            $matches->{$field}->{$query}->{'users'}  = $users;
            $matches->{$field}->{$query}->{'status'} = 'success';

            # here is where it checks for multiple matches

            if (scalar(@{$users}) == 1) { # exactly one match
                # delimit with spaces if necessary
                if ($vars->{'form'}->{$field}) {
                    $vars->{'form'}->{$field} .= " ";
                }
                $vars->{'form'}->{$field} .= @{$users}[0]->{'login'};
                push @{$vars->{'mform'}->{$field}}, @{$users}[0]->{'login'};
                $need_confirm = 1 if &::Param('confirmuniqueusermatch');

            }
            elsif ((scalar(@{$users}) > 1)
                    && (&::Param('maxusermatches') != 1)) {
                $need_confirm = 1;

                if ((&::Param('maxusermatches'))
                   && (scalar(@{$users}) > &::Param('maxusermatches')))
                {
                    $matches->{$field}->{$query}->{'status'} = 'trunc';
                    pop @{$users};  # take the last one out
                }

            }
            else {
                # everything else fails
                $matchsuccess = 0; # fail
                $matches->{$field}->{$query}->{'status'} = 'fail';
                $need_confirm = 1;  # confirmation screen shows failures
            }
        }
    }

    return 1 unless $need_confirm; # skip confirmation if not needed.

    $vars->{'script'}        = $ENV{'SCRIPT_NAME'}; # for self-referencing URLs
    $vars->{'fields'}        = $fields; # fields being matched
    $vars->{'matches'}       = $matches; # matches that were made
    $vars->{'matchsuccess'}  = $matchsuccess; # continue or fail

    print Bugzilla->cgi->header();

    $::template->process("global/confirm-user-match.html.tmpl", $vars)
      || ThrowTemplateError($::template->error());

    exit;

}

sub email_prefs {
    # Get or set (not implemented) the user's email notification preferences.
    
    my $self = shift;
    return {} unless $self->id;
    
    # If the calling code is setting the email preferences, update the object
    # but don't do anything else.  This needs to write email preferences back
    # to the database.
    if (@_) { $self->{email_prefs} = shift; return; }
    
    # If we already got them from the database, return the existing values.
    return $self->{email_prefs} if $self->{email_prefs};
    
    # Retrieve the values from the database.
    &::SendSQL("SELECT emailflags FROM profiles WHERE userid = $self->{id}");
    my ($flags) = &::FetchSQLData();

    my @roles = qw(Owner Reporter QAcontact CClist Voter);
    my @reasons = qw(Removeme Comments Attachments Status Resolved Keywords 
                     CC Other Unconfirmed);

    # Convert the prefs from the flags string from the database into
    # a Perl record.  The 255 param is here because split will trim 
    # any trailing null fields without a third param, which causes Perl 
    # to eject lots of warnings. Any suitably large number would do.
    my $prefs = { split(/~/, $flags, 255) };
    
    # Determine the value of the "excludeself" global email preference.
    # Note that the value of "excludeself" is assumed to be off if the
    # preference does not exist in the user's list, unlike other 
    # preferences whose value is assumed to be on if they do not exist.
    $prefs->{ExcludeSelf} = 
      exists($prefs->{ExcludeSelf}) && $prefs->{ExcludeSelf} eq "on";
    
    # Determine the value of the global request preferences.
    foreach my $pref (qw(FlagRequestee FlagRequester)) {
        $prefs->{$pref} = !exists($prefs->{$pref}) || $prefs->{$pref} eq "on";
    }
    
    # Determine the value of the rest of the preferences by looping over
    # all roles and reasons and converting their values to Perl booleans.
    foreach my $role (@roles) {
        foreach my $reason (@reasons) {
            my $key = "email$role$reason";
            $prefs->{$key} = !exists($prefs->{$key}) || $prefs->{$key} eq "on";
        }
    }

    $self->{email_prefs} = $prefs;
    
    return $self->{email_prefs};
}

sub get_userlist {
    my $self = shift;

    return $self->{'userlist'} if defined $self->{'userlist'};

    my $query  = "SELECT DISTINCT login_name, realname,";
    if (&::Param('usevisibilitygroups')) {
        $query .= " COUNT(group_id) ";
    } else {
        $query .= " 1 ";
    }
        $query .= "FROM profiles ";
    if (&::Param('usevisibilitygroups')) {
        $query .= "LEFT JOIN user_group_map " .
                  "ON user_group_map.user_id = userid AND isbless = 0 " .
                  "AND group_id IN(" .
                  join(', ', (-1, @{$self->visible_groups_inherited})) . ") " .
                  "AND grant_type <> " . GRANT_DERIVED;
    }
    $query    .= " WHERE disabledtext = '' GROUP BY userid";

    my $dbh = Bugzilla->dbh;
    my $sth = $dbh->prepare($query);
    $sth->execute;

    my @userlist;
    while (my($login, $name, $visible) = $sth->fetchrow_array) {
        push @userlist, {
            login => $login,
            identity => $name ? "$name <$login>" : $login,
            visible => $visible,
        };
    }
    @userlist = sort { lc $$a{'identity'} cmp lc $$b{'identity'} } @userlist;

    $self->{'userlist'} = \@userlist;
    return $self->{'userlist'};
}

sub insert_new_user ($$) {
    my ($username, $realname) = (@_);
    my $dbh = Bugzilla->dbh;

    # Generate a new random password for the user.
    my $password = &::GenerateRandomPassword();
    my $cryptpassword = bz_crypt($password);

    # XXX - These should be moved into ValidateNewUser or CheckEmailSyntax
    #       At the least, they shouldn't be here. They're safe for now, though.
    trick_taint($username);
    trick_taint($realname);

    # Insert the new user record into the database.
    $dbh->do("INSERT INTO profiles 
                          (login_name, realname, cryptpassword, emailflags) 
                   VALUES (?, ?, ?, ?)",
             undef, 
             ($username, $realname, $cryptpassword, DEFAULT_EMAIL_SETTINGS));

    # Return the password to the calling code so it can be included
    # in an email sent to the user.
    return $password;
}

sub is_available_username ($;$) {
    my ($username, $old_username) = @_;

    if(login_to_id($username) != 0) {
        return 0;
    }

    my $dbh = Bugzilla->dbh;
    # $username is safe because it is only used in SELECT placeholders.
    trick_taint($username);
    # Reject if the new login is part of an email change which is
    # still in progress
    #
    # substring/locate stuff: bug 165221; this used to use regexes, but that
    # was unsafe and required weird escaping; using substring to pull out
    # the new/old email addresses and locate() to find the delimeter (':')
    # is cleaner/safer
    my $sth = $dbh->prepare(
        "SELECT eventdata FROM tokens WHERE tokentype = 'emailold'
        AND SUBSTRING(eventdata, 1, (LOCATE(':', eventdata) - 1)) = ?
        OR SUBSTRING(eventdata, (LOCATE(':', eventdata) + 1)) = ?");
    $sth->execute($username, $username);

    if (my ($eventdata) = $sth->fetchrow_array()) {
        # Allow thru owner of token
        if($old_username && ($eventdata eq "$old_username:$username")) {
            return 1;
        }
        return 0;
    }

    return 1;
}

sub login_to_id ($) {
    my ($login) = (@_);
    my $dbh = Bugzilla->dbh;
    my $user_id = $dbh->selectrow_array(
        "SELECT userid FROM profiles WHERE login_name = ?", undef, $login);
    # $user_id should be a positive integer, this makes Taint mode happy
    if (defined $user_id && detaint_natural($user_id)) {
        return $user_id;
    } else {
        return 0;
    }
}

1;

__END__

=head1 NAME

Bugzilla::User - Object for a Bugzilla user

=head1 SYNOPSIS

  use Bugzilla::User;

  my $user = new Bugzilla::User($id);

  # Class Functions
  $random_password = insert_new_user($username, $realname);

=head1 DESCRIPTION

This package handles Bugzilla users. Data obtained from here is read-only;
there is currently no way to modify a user from this package.

Note that the currently logged in user (if any) is available via
L<Bugzilla-E<gt>user|Bugzilla/"user">.

=head1 METHODS

=over 4

=item C<new($userid)>

Creates a new C{Bugzilla::User> object for the given user id.  If no user
id was given, a blank object is created with no user attributes.

If an id was given but there was no matching user found, undef is returned.

=begin undocumented

=item C<new_from_login($login)>

Creates a new C<Bugzilla::User> object given the provided login. Returns
C<undef> if no matching user is found.

This routine should not be required in general; most scripts should be using
userids instead.

This routine and C<new> both take an extra optional argument, which is
passed as the argument to C<derive_groups> to avoid locking. See that
routine's documentation for details.

=end undocumented

=item C<id>

Returns the userid for this user.

=item C<login>

Returns the login name for this user.

=item C<email>

Returns the user's email address. Currently this is the same value as the
login.

=item C<name>

Returns the 'real' name for this user, if any.

=item C<showmybugslink>

Returns C<1> if the user has set his preference to show the 'My Bugs' link in
the page footer, and C<0> otherwise.

=item C<identity>

Retruns a string for the identity of the user. This will be of the form
C<name E<lt>emailE<gt>> if the user has specified a name, and C<email>
otherwise.

=item C<nick>

Returns a user "nickname" -- i.e. a shorter, not-necessarily-unique name by
which to identify the user. Currently the part of the user's email address
before the at sign (@), but that could change, especially if we implement
usernames not dependent on email address.

=item C<queries>

Returns an array of the user's named queries, sorted in a case-insensitive
order by name. Each entry is a hash with three keys:

=over

=item *

name - The name of the query

=item *

query - The text for the query

=item *

linkinfooter - Whether or not the query should be displayed in the footer.

=back

=item C<flush_queries_cache>

Some code modifies the set of stored queries. Because C<Bugzilla::User> does
not handle these modifications, but does cache the result of calling C<queries>
internally, such code must call this method to flush the cached result.

=item C<groups>

Returns a hashref of group names for groups the user is a member of. The keys
are the names of the groups, whilst the values are the respective group ids.
(This is so that a set of all groupids for groups the user is in can be
obtained by C<values(%{$user->groups})>.)

=item C<in_group>

Determines whether or not a user is in the given group. This method is mainly
intended for cases where we are not looking at the currently logged in user,
and only need to make a quick check for the group, where calling C<groups>
and getting all of the groups would be overkill.

=item C<can_see_bug(bug_id)>

Determines if the user can see the specified bug.

=item C<derive_groups>

Bugzilla allows for group inheritance. When data about the user (or any of the
groups) changes, the database must be updated. Handling updated groups is taken
care of by the constructor. However, when updating the email address, the
user may be placed into different groups, based on a new email regexp. This
method should be called in such a case to force reresolution of these groups.

=item C<get_selectable_products(by_id)>

Returns an alphabetical list of product names from which
the user can select bugs.  If the $by_id parameter is true, it returns
a hash where the keys are the product ids and the values are the
product names.

=item C<get_userlist>

Returns a reference to an array of users.  The array is populated with hashrefs
containing the login, identity and visibility.  Users that are not visible to this
user will have 'visible' set to zero.

=item C<flatten_group_membership>

Accepts a list of groups and returns a list of all the groups whose members 
inherit membership in any group on the list.  So, we can determine if a user
is in any of the groups input to flatten_group_membership by querying the
user_group_map for any user with DIRECT or REGEXP membership IN() the list
of groups returned.

=item C<visible_groups_inherited>

Returns a list of all groups whose members should be visible to this user.
Since this list is flattened already, there is no need for all users to
be have derived groups up-to-date to select the users meeting this criteria.

=item C<visible_groups_direct>

Returns a list of groups that the user is aware of.

=begin undocumented

This routine takes an optional argument. If true, then this routine will not
lock the tables, but will rely on the caller to have done so itsself.

This is required because mysql will only execute a query if all of the tables
are locked, or if none of them are, not a mixture. If the caller has already
done some locking, then this routine would fail. Thus the caller needs to lock
all the tables required by this method, and then C<derive_groups> won't do
any locking.

This is a really ugly solution, and when Bugzilla supports transactions
instead of using the explicit table locking we were forced to do when thats
all MySQL supported, this will go away.

=end undocumented

=item C<can_bless>

Returns C<1> if the user can bless at least one group. Otherwise returns C<0>.

=item C<set_flags>
=item C<get_flag>

User flags are template-accessible user status information, stored in the form
of a hash.  For an example of use, when the current user is authenticated in
such a way that they are allowed to log out, the 'can_logout' flag is set to
true (1).  The template then checks this flag before displaying the "Log Out"
link.

C<set_flags> is called with any number of key,value pairs.  Flags for each key
will be set to the specified value.

C<get_flag> is called with a single key name, which returns the associated
value.

=back

=head1 CLASS FUNCTIONS

=over4

These are functions that are not called on a User object, but instead are
called "statically," just like a normal procedural function.

=item C<insert_new_user>

Creates a new user in the database with a random password.

Params: $username (scalar, string) - The login name for the new user.
        $realname (scalar, string) - The full name for the new user.

Returns: The password that we randomly generated for this user, in plain text.

=item C<is_available_username>

Returns a boolean indicating whether or not the supplied username is
already taken in Bugzilla.

Params: $username (scalar, string) - The full login name of the username 
            that you are checking.
        $old_username (scalar, string) - If you are checking an email-change
            token, insert the "old" username that the user is changing from,
            here. Then, as long as it's the right user for that token, he 
            can change his username to $username. (That is, this function
            will return a boolean true value).

=back

=item C<login_to_id($login)>

Takes a login name of a Bugzilla user and changes that into a numeric
ID for that user. This ID can then be passed to Bugzilla::User::new to
create a new user.

If no valid user exists with that login name, then the function will return 0.

This function can also be used when you want to just find out the userid
of a user, but you don't want the full weight of Bugzilla::User.

However, consider using a Bugzilla::User object instead of this function
if you need more information about the user than just their ID.

=head1 SEE ALSO

L<Bugzilla|Bugzilla>

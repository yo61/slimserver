package Slim::Utils::Text;

# $Id$

# SlimServer Copyright (c) 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

use Slim::Utils::Prefs;

my $prefs = preferences('server');

our %caseArticlesCache = ();

# Article list to ignore.
our $ignoredArticles = undef;

=head1 NAME

Slim::Utils::Text

=head1 SYNOPSIS

my $clean = Slim::Utils::Text::ignorePunct('foo! bar?');

=head1 DESCRIPTION

A collection of text mangling functions.

=head1 METHODS

=head2 ignorePunct( $string )

Strips any punctuation, compacts multiple spaces, and removes leading & trailing whitespace.

=cut

sub ignorePunct {
	my $s = shift;

	if (!defined $s) {
		return undef;
	}

	my $orig = $s;

	$s =~ s/[[:punct:]]+/ /go;
	$s =~ s/  +/ /go; # compact multiple spaces, "L.A. Mix" -> "L A Mix", not "L A  Mix"
	$s =~ s/^ +//o; # zap leading/trailing spaces.
	$s =~ s/ +$//o;

	$s = $orig if $s eq '';

	return $s;
}

=head2 matchCase( $string )

Translates lowercase US-ASCII and ISO-8859-1 to their uppercase equivalents.

Also merges ISO-8859-1 strings like AE (\xC3\x86) into 'AE'.

=cut

sub matchCase {
	my $s = shift;

	if (!defined $s) {
		return undef;
	}

	# Upper case and fold latin1 diacritical characters into their plain versions, surprisingly useful.
	$s =~ tr{abcdefghijklmnopqrstuvwxyz��������Ǣ����������������������������������������������������}
		{ABCDEFGHIJKLMNOPQRSTUVWXYZAAAAAABBCCDEEEEIIIINOOOOOOUUUUXYAAAAAABCEEEEIIIINOOOOOOUUUUYYD!D};

	# Turn � & � into AE
	$s =~ s/\xC6/AE/go;
	$s =~ s/\xC3\x86/AE/go;

	# and the lowercase version
	$s =~ s/\xE6/AE/go;
	$s =~ s/\xC3\xA6/AE/go;

	# And � into MU
	$s =~ s/\xB5/MU/go;
	$s =~ s/\xC2\xB5/MU/go;

	return $s;
}

=head2 ignoreArticles( $string )

Removes leading articles as defined by the 'ignoredarticles' preference.

=cut

sub ignoreArticles {
	my $item = shift;

	if (!defined $item) {
		return undef;
	}

	if (!defined($ignoredArticles)) {

		$ignoredArticles = $prefs->get('ignoredarticles');

		# allow a space seperated list in preferences (easier for humans to deal with)
		$ignoredArticles =~ s/\s+/|/g;

		$ignoredArticles = qr/^($ignoredArticles)\s+/i;
	}

	# set up array for sorting items without leading articles
	$item =~ s/$ignoredArticles//;

	return $item;
}

=head2 ignoreCaseArticles( $string )

Runs L<ignoreArticles> and L<ignorePunct> on the passed string. Additionally,
strip out characters beyond U+FFFF as MySQL doesn't like them in TEXT fields.

=cut

sub ignoreCaseArticles {
	my $s = shift;

	if (!defined $s) {
		return undef;
	}

	# We don't handle references of any kind.
	if (ref($s)) {
		return $s;
	}

	if (scalar keys %caseArticlesCache > 256) {
		%caseArticlesCache = ();
	}

	if (!$caseArticlesCache{$s}) {

		use locale;

		$caseArticlesCache{$s} = ignorePunct(ignoreArticles(uc($s)));

		# Remove characters beyond U+FFFF as MySQL doesn't like them in TEXT fields
		$caseArticlesCache{$s} =~ s/[\x{10000}-\x{10ffff}]//g;

		# strip leading & trailing spaces
		$caseArticlesCache{$s} =~ s/^ +//o;
		$caseArticlesCache{$s} =~ s/ +$//o;
	}

	return $caseArticlesCache{$s};
}

=head2 clearCaseArticleCache()

Clear the internal cache for strings.

=cut

sub clearCaseArticleCache {

	%caseArticlesCache = ();
	$ignoredArticles   = undef;

	return 1;
}

=head2 searchStringSplit( $string, $searchOnSubString )

Returns an array ref of strings, suitable for being passed to to
L<SQL::Abstract> as part of a LIKE SQL query. If the $searchOnSubString
argument is passed, the result will look for matches like: *FOO*, instead of:
'FOO*' and '* FOO*'

=cut

sub searchStringSplit {
	my $search  = shift;
	my $searchSubString = shift;

	$searchSubString = defined $searchSubString ? $searchSubString : $prefs->get('searchSubString');

	# normalize the string
	$search = Slim::Utils::Unicode::utf8decode_locale($search);
	$search = ignoreCaseArticles($search);

	my @strings = ();

	# Don't split - causes an explict AND, which is what we want.. I think.
	# for my $string (split(/\s+/, $search)) {
	my $string = $search;

		if ($searchSubString) {

			push @strings, "\%$string\%";

		} else {

			push @strings, [ "$string\%", "\% $string\%" ];
		}
	#}

	return \@strings;
}

1;

__END__

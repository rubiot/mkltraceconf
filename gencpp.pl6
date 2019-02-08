#! /usr/bin/env perl6

use v6;
use Terminal::ANSIColor;
#use Grammar::Tracer;

#my $current-class-name;

grammar CPP::Header {
  rule TOP {
    ^
    [
      || <compiler-directive>
      || <declaration>
    ]+ % <.ws>
    $
  }

  token ws {
    <!ww> [ \s || <.comment> ]*
  }

  proto token comment {*}

  token comment:sym<//> {
    <sym> \N*
  }

  token comment:sym</*> {
    <sym> ~ '*/' .*?
  }

  proto token declaration {*}

  rule declaration:sym<struct> {
    $<declaration-type>=[ 'struct' | 'union' ] $<name>=<.identifier>? <struct-body>? ';'
  }

  rule declaration:sym<class> {
    $<declaration-type>='class' <class-name> <class-body>? ';'
  }

  rule declaration:sym<variable> {
    <type> <identifier> ';'
  }

  rule declaration:sym<enum> {
    $<declaration-type>='enum' <identifier>?
    '{' ~ '}' <enum-value>+ % ','
    ';'
  }

  rule struct-body {
    '{' ~ '}' [ <struct-declaration> || <variable-declaration> ]+ %% <.ws>
  }

  rule enum-value {
    <identifier> [ '=' \d+ ]?
  }

  token compiler-directive {
    '#' \N+ [ <after '\\'> \n\N+ ]*
  }

  rule class-body {
    '{' ~ '}'
    [
      || <method>
      || <visibility>
      || <declaration> # for now, for this allows classes within classes
      #|| <variable-declaration>
      #|| <enum-declaration>
    ]+
  }

  token identifier {
    <!before <[0..9]>> <[ a..z A..Z 0..9 _]>+
  }

  token class-name {
    <.identifier>
  }

  token visibility {
    <( <.visibility-keyword> )> <.ws>? ':'
  }

  proto token visibility-keyword          {   *   }
  token visibility-keyword:sym<private>   { <sym> }
  token visibility-keyword:sym<public>    { <sym> }
  token visibility-keyword:sym<protected> { <sym> }

  #  rule attribute {
  #    <.type> <.identifier> ';'
  #  }

  rule method {
    <method-pre-modifier>?
    <method-signature>
    <method-post-modifier>?
    <method-body>
    #{ say "visibilidade: << $*VISIBILITY >> " }
    #$<visibility>={ $*VISIBILITY }
  }

  token method-pre-modifier {
    'virtual' | 'inline' | 'static'
  }

  rule method-post-modifier {
    'const' || [ '=' '0' ]
  }

  proto token method-signature {*}

  token method-signature:sym<constructor> {
    <.identifier>
    <.ws>?
    <argument-list>
  }

  token method-signature:sym<destructor> {
    '~' <.identifier> <.ws>?
    <argument-list>
  }

  token method-signature:sym<method> {
    <return-type> <.ws> <method-name> <.ws>? <argument-list>
  }

  token argument-list {
    '(' ~ ')' <argument>* % ','
  }

  rule argument {
    <type> [ $<name>=<.identifier> [ '=' <literal> ]? ]?
  }

  proto token literal {*}
  token literal:integer    { \d+               }
  token literal:float      { [ \d+ ]? '.' \d+  }
  token literal:boolean    { 'true' | 'false'  }
  token literal:null       { 'NULL'            }
  token literal:std_string { 'std::string()'   }
  token literal:constant   { <.identifier>     }
  #token literal:flags { 'flags(' <.ws> \d+ <.ws> ')' }

  proto rule method-body {*}

  token method-body:sym<without-body> {
    ';'
  }

  token method-body:sym<with-body> {
    '{' ~ [ '}' ';'? ] .*?
  }

  token return-type {
    <.type>
  }

  proto rule type {*}

  rule type:sym<builtin> {
    'const'?
    [
      | 'long'? <.numeric-type>
      | 'char'
      | 'void'
      | 'bool'
    ]
    [
      | '&'
      | '*'*
    ]
  }

  rule type:sym<user-defined> {
    'const'?
    [
      | 'struct'
      | 'enum'
      | 'union'
    ]?
    <.identifier>
    [
      | '&'
      | '*'*
    ]
  }

  token numeric-type {
    'int' | 'long' | 'float'
  }

  rule method-name {
    <.identifier>
  }
}

class CPPHeaderActions {
  has $.current-visibility = 'private';

  method TOP ($/) {
    make $<TOP>.made;
  }

  method declaration:sym<class> ($/) {
    say "new class declaration found: $<class-name>";
    #say $/;
    for $<class-body><method> -> $m {
      #print colored(~$m<visibility>, 'green');
      say "        " ~ $m<method-signature>.trim
    }
  }

  method declaration:sym<struct> ($/) {
    say "new struct found: $/";
  }

  method method-signature:sym<constructor> ($/) {
    say "new $!current-visibility constructor found: $/"
  }

  method method-signature:sym<destructor> ($/) {
    say " new $!current-visibility destructor found: $/"
  }

  method method-signature:sym<method> ($/) {
    print colored("     new $!current-visibility method found: ", 'yellow');
    say ~$/;

    #make $/<method><visibility> = $*VISIBILITY;
    #$<visibility> = $*VISIBILITY;
    #make $/.made;
    make "$!current-visibility $/";
    #my %h = $/.hash;
    #%h<visibility> = $!current-visibility // 'private';
    #make %h;
  }

  method class-name($/) {
    say "      new class found: $/"
  }

  #  method type:sym<builtin>($/) {
  #    #say ">>>>>>> " ~ $/.ast;
  #    #say ">>> " ~ $<type>.ast;
  #    make $<type>.made
  #  }

  method visibility ($/) {
    $!current-visibility = ~$/;
    make $<visibility>.made
  }
}

sub MAIN(:$h!) {
  my $actions = CPPHeaderActions.new;
  CPP::Header.parsefile($h, :actions($actions)) || die "Erro na varredura do header $h";
  say $/;
}

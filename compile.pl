#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

use Getopt::Long;

my %opt;
die unless GetOptions(\%opt, 'trace', 'labels');

local $/;
my $asm = <>;
my ($bytecode, $label_addr) = compile($asm,\%opt);
if ($opt{trace}) {
  warn "\n";
}
if ($opt{labels}) {
  warn "$label_addr->{$_}\t$_\n" for sort keys %$label_addr;
  warn "\n";
}
print join(",", @$bytecode)."\n";

sub compile {
  my ($asm, $opt) = @_;

  $opt ||= {};

  my %instr = (
    hlt => { opcode=>99, args=>0, lvals=>[], },
    add => { opcode=> 1, args=>3, lvals=>[0,0,1], },
    mul => { opcode=> 2, args=>3, lvals=>[0,0,1], },
    in  => { opcode=> 3, args=>1, lvals=>[1], },
    out => { opcode=> 4, args=>1, lvals=>[0], },
    jt  => { opcode=> 5, args=>2, lvals=>[0,0], },
    jf  => { opcode=> 6, args=>2, lvals=>[0,0], },
    lt  => { opcode=> 7, args=>3, lvals=>[0,0,1], },
    eq  => { opcode=> 8, args=>3, lvals=>[0,0,1], },
    rbo => { opcode=> 9, args=>1, lvals=>[0], },
  );

  my %str_escape = (
    '\\' => "\\",
    'n'  => "\n",
    't'  => "\t",
    '"' => '"',
    "'" => "'",
    's'  => " ", #so tokens like '\s' have no whitespace for regexes like /(\S+)/
  );

  my @compiled;
  my @lines = grep {/\S/} split(/\n/, $asm);

  my %label_addr;
  my %label_mode;
  my %label_uses;
  my $label_prefix = "";
  my %label_prefix_except;

  my %functions;

  my $warn = sub {
    warn "\e[33m[warn]\e[0m $_[0]\n";
  };

  my $_cur_uid = 0;
  my $gen_uid = sub { ++$_cur_uid };

  my %macro = (
    fn => sub {
      my ($line) = @_;
      die '@fn when not in top scope' unless $label_prefix eq '';
      die if %label_prefix_except;

      die "invalid \@fn declaration" unless $line =~ /^\@fn\s+(\d+)\s+(\w+)\(\s*([^\)]*?)\s*\)(?:\s+local\(\s*([^\)]+?)\s*\))?(?:\s+global\(\s*([^\)]+?)\s*\))?\s*$/;
      my ($retnum, $fnname, $arglist, $locallist, $globallist) = ($1, $2, $3, $4, $5);

      die "duplicate function $fnname" if $functions{$fnname};
      die "function label $fnname is already used elsewhere" if exists $label_addr{$fnname} || exists $label_mode{$fnname};

      $label_addr{$fnname} = @compiled;

      my @args    =                       split(/\,\s*/, $arglist   );      die "invalid function $fnname arglist"    if grep {!/^(?!\d)\w+$/} @args;
      my @locals  = defined $locallist  ? split(/\,\s*/, $locallist ) : (); die "invalid function $fnname locallist"  if grep {!/^(?!\d)\w+$/} @locals;
      my @globals = defined $globallist ? split(/\,\s*/, $globallist) : (); die "invalid function $fnname globallist" if grep {!/^(?!\d)\w+$/} @globals;

      my %use_num; $use_num{$_}++ for (@args, @locals, @globals);
      die "duplicate label in \@fn $fnname declaration" if grep {$_>1} values %use_num;

      die if $fnname =~ /__/;
      $label_prefix = "fn_${fnname}__";
      %label_prefix_except = map {$_=>1} (@globals, $fnname);

      # new labels get prefix, but abort if it matches any global
      # label uses get prefix except globals
      # all args become ~-4, ~-3, ...
      # all locals become ..., ~-2, ~-1
      # return0 is ~-4, return1 is ~-3, ...
      #
      # #pass0 is ~1, pass1 is ~2, ...

      my $mk_label = sub {
        my ($label, $addr, $mode) = @_;
        die unless defined $label && defined $addr && defined $mode;
        $label = $label_prefix.$label;
        die "duplicate label $label during function declaration" if exists $label_addr{$label} || exists $label_mode{$label};
        $label_addr{$label} = $addr;
        $label_mode{$label} = $mode;
      };

      my @stack_vars = (@args, @locals);
      for (my $i=0; $i<@stack_vars; $i++) {
        $mk_label->($stack_vars[$i], $i-@stack_vars, 2);
      }

      for (my $i=0; $i<$retnum; $i++) {
        $mk_label->("return$i", $i-@stack_vars, 2); #this is allowed to reach ~0, ~1, ~2, ...
      }

      my $stack_size = 1 + @stack_vars; #retval + stack vars

      $functions{$fnname} = {
        stack_size => $stack_size,
      };

      return (
        "rbo $stack_size",
      );
    },
    endfn => sub {
      my ($line) = @_;
      die unless $line eq '@endfn';
      die '@endfn when not in function' unless $label_prefix =~ /^fn_(\w+?)__/;
      my $fnname = $1;
      die "\@endfn during unknown function $fnname" unless $functions{$fnname};
      $label_prefix = "";
      %label_prefix_except = ();
      return (
        "rbo -$functions{$fnname}{stack_size}",
        '@jmp ~0',
      );
    },
    call => sub {
      my ($line) = @_;
      die unless $line =~ /^\@call\s+(\S+)\s*$/;
      my $fnexpr = $1;
      $warn->("\@call $fnexpr is not an address") unless $fnexpr =~ /^(?:\w+\:)?\&\w+$/;
      my $ret_label = "retaddr".$gen_uid->();
      return (
        "\@cpy &$ret_label ~0",
        "\@jmp $fnexpr",
        "$ret_label:",
      );
    },
    cpy => sub {
      my ($line) = @_;
      die "\@cpy line invalid: $line" unless $line =~ /^\@cpy\s+(\S+)\s+(\S+)\s*$/;
      my ($src, $dst) = ($1, $2);
      my ($op, $arg) = rand()<.5 ? ("add",0) : ("mul",1);
      return rand()<.5 ? "$op $src $arg $dst" : "$op $arg $src $dst";
    },
    jmp => sub {
      my ($line) = @_;
      die unless $line =~ /^\@jmp\s+(\S+)\s*$/;
      my ($addr) = ($1);
      my ($op, $arg) = rand()<.5 ? ("jt",1) : ("jf",0);
      return "$op $arg $addr";
    },
    str => sub {
      my ($line) = @_;
      die "invalid string macro: $line" unless $line =~ /^\@str\s+(?:(\w+)\:\s*)?\"(.*?)\"\s*$/;
      my ($label, $str) = ($1,$2);
      $str =~ s/\\(.)/$str_escape{$1} \/\/ die "unknown str escape for $1"/ge;
      return '@raw '.(defined $label ? "$label:" : "").join(" ", length($str), map {ord($_)} split(//,$str));
    },
  );

  for (my $line_i=0; $line_i<@lines; $line_i++) {
    my $line = $lines[$line_i];
    $line =~ s/^\s+|\s+$//g;
    next if $line =~ /^\s*(?:\#.*?)?$/;

    if ($line =~ /^\@(\w+)/ && $macro{$1}) {
      warn "\e[1;31m$line\e[0m\n" if $opt->{trace};
      splice(@lines, $line_i, 1, $macro{$1}($line));
      redo;
    }

    warn "\e[36m$line\e[0m\n" if $opt->{trace};

    my @in_vals = grep {/\S/} split(/\s+/, $line);
    my @out_vals;

    my $linemode = '';
    if ($in_vals[0] eq '@raw') {
      shift @in_vals;
      $linemode = 'raw';
    }

    for (my $i=0; $i<@in_vals; $i++) {
      while ($in_vals[$i] =~ s/^((?!\d)\w+)\://) {
        my $label = lc $1;
        die "attempted declaration of prefix-excepted label $label (probably overlaps predeclared global)" if $label_prefix_except{$label};
        die "double underscore in labels is reserved" if $label =~ /__/;
        $label = "$label_prefix$label";
        die "duplicate label $label" if exists $label_addr{$label};
        $label_addr{$label} = @compiled + $i;
      }
      if ($in_vals[$i] !~ /\S/) {
        shift @in_vals;
        last unless @in_vals;
        redo;
      }
      if ($in_vals[$i] =~ /^\'(?:([^\'\\])|\\(.))\'$/) {
        my ($literal, $escaped) = ($1, $2);
        if (defined $literal) {
          $in_vals[$i] = ord($literal);
        } elsif (defined $escaped) {
          die "unknown escape sequence \\$escaped in char" unless exists $str_escape{$escaped};
          $in_vals[$i] = ord($str_escape{$escaped});
        } else {
          die 'unreachable';
        }
      }

      if ($i == 0 && $linemode ne 'raw') {
        if ($in_vals[0] =~ /^\-?\d+$/) {
          $warn->("using literal value as opcode with no parameter validation in line: $line");
          $out_vals[$i] = $in_vals[0];
        } else {
          die "unknown instruction $in_vals[0] in line: $line" unless exists $instr{$in_vals[0]};
          die "wrong number of args for instruction $in_vals[0] of line: $line" unless @in_vals == $instr{$in_vals[0]}{args}+1;
          die "wrong length lval definition for instruction $in_vals[0]" unless $instr{$in_vals[0]}{args} == @{$instr{$in_vals[0]}{lvals}};
          $out_vals[$i] = $instr{$in_vals[0]}{opcode};

					$warn->("jump to variable address in line: $line") if $in_vals[0] =~ /^j[tf]$/ && $in_vals[2] !~ /^(?:\w+\:)?(?:\&\w+|\~0)$/;
				}
      } else {
        my $addr_mode;

        if ($in_vals[$i] =~ /^([\*\~]?)(\-?\d+)$/) {
          my ($mode_str, $val) = ($1, $2);
          $addr_mode = $mode_str eq '*' ? 0 : $mode_str eq '' ? 1 : $mode_str eq '~' ? 2 : die;
          $out_vals[$i] = $val;
        } elsif ($in_vals[$i] =~ /^([\&]?)([a-z_]\w*)$/i) {
          my ($mode_str, $label) = ($1, lc $2);
          $label = "$label_prefix$label" unless $label_prefix_except{$label};
          if (exists $label_mode{$label}) {
            die "mode flag illegal on label $label with defined mode $label_mode{$label}" if $mode_str ne '';
            $addr_mode = $label_mode{$label};
          } else {
            $addr_mode = $mode_str eq '&' ? 1 : 0;
          }
          $out_vals[$i] = "LABEL";
          push @{$label_uses{$label}}, @compiled + $i;
        } else {
          die "unrecognized value <$in_vals[$i]> at index $i of line: $line";
        }

        if ($linemode eq 'raw') {
          die "values must be immediate in raw line: $line" unless $addr_mode == 1;
        } else {
          die "immediate value in lval parameter in line: $line" if $addr_mode == 1 && $instr{$in_vals[0]} && $instr{$in_vals[0]}{lvals}[$i-1];
          $out_vals[0] += $addr_mode * 10**($i+1);
        }
      }
    }

    die "instruction $in_vals[0]} produced wrong number of out vals in line: $line" if $linemode ne 'raw' && @in_vals && $instr{$in_vals[0]} && @out_vals != $instr{$in_vals[0]}{args}+1;

    push @compiled, @out_vals;
  }

  $label_addr{auto__end} = scalar @compiled;

  my @issues;
  for my $label (keys %label_uses) {
    for my $use_addr (@{$label_uses{$label}}) {
      push @issues, "label $label addr $use_addr somehow outside of compiled bounds" if $use_addr > $#compiled;
      push @issues, "label $label referenced but never defined" unless exists $label_addr{$label};
      $compiled[$use_addr] = $label_addr{$label};
    }
  }
  for my $label (keys %label_addr) {
    push @issues, "label $label defined but never referenced" unless exists $label_uses{$label} || $label =~ /^auto__/;
  }

  if (@issues) {
    warn map{"- $_\n"} sort @issues;
    die +(scalar @issues)." issue(s) found";
  }

  die if grep {$_ eq 'LABEL'} @compiled;

  return (\@compiled, \%label_addr);
}

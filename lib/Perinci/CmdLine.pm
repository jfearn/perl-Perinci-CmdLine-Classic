package Perinci::CmdLine;

use 5.010001;
#use strict; # enabled by Moo
#use warnings; # enabled by Moo
use Log::Any '$log';

use Data::Dump::OneLine qw(dump1);
use Moo;
use experimental 'smartmatch'; # must be after Moo
use Locale::TextDomain 'Perinci-CmdLine';
use Perinci::Object;
use Perinci::ToUtil;
use Scalar::Util qw(reftype blessed);

# VERSION

with 'SHARYANTO::Role::ColorTheme' unless $ENV{COMP_LINE};
#with 'SHARYANTO::Role::TermAttrs' unless $ENV{COMP_LINE}; already loaded by ColorTheme

has program_name => (
    is => 'rw',
    lazy => 1,
    default => sub {
        my $pn = $ENV{PERINCI_CMDLINE_PROGRAM_NAME};
        if (!defined($pn)) {
            $pn = $0; $pn =~ s!.+/!!;
        }
        $pn;
    }
);
has url => (is => 'rw');
has summary => (is => 'rw');
has description => (is => 'rw');
has subcommands => (is => 'rw');
has default_subcommand => (is => 'rw');
has exit => (is => 'rw', default=>sub{1});
has log_any_app => (is => 'rw', default=>sub{1});
has custom_completer => (is => 'rw');
has custom_arg_completer => (is => 'rw');
has pass_cmdline_object => (is => 'rw', default=>sub{0});
has undo => (is=>'rw', default=>sub{0});
has undo_dir => (
    is => 'rw',
    lazy => 1,
    default => sub {
        require File::HomeDir;

        my $self = shift;
        my $dir = File::HomeDir->my_home . "/." . $self->program_name;
        mkdir $dir unless -d $dir;
        $dir .= "/.undo";
        mkdir $dir unless -d $dir;
        $dir;
    }
);
has format => (is => 'rw', default=>sub{'text'});
# bool, is format set via cmdline opt?
has format_set => (is => 'rw');
has format_options => (is => 'rw');
# bool, is format_options set via cmdline opt?
has format_options_set => (is => 'rw');
has pa_args => (is => 'rw');
has _pa => (
    is => 'rw',
    lazy => 1,
    default => sub {
        my $self = shift;

        require Perinci::Access;
        require Perinci::Access::Perl;
        require Perinci::Access::Schemeless;
        my %args = %{$self->pa_args // {}};
        my %opts;
        # turn off arg validation generation to reduce startup cost
        $opts{extra_wrapper_args} = 0 if $ENV{COMP_LINE};
        if ($self->undo) {
            $opts{use_tx} = 1;
            $opts{custom_tx_manager} = sub {
                my $pa = shift;
                require Perinci::Tx::Manager;
                state $txm = Perinci::Tx::Manager->new(
                    data_dir => $self->undo_dir,
                    pa => $pa,
                );
                $txm;
            };
        }
        $args{handlers} = {
            pl => Perinci::Access::Perl->new(%opts),
            '' => Perinci::Access::Schemeless->new(%opts),
        };
        #$log->tracef("Creating Perinci::Access object with args: %s", \%args);
        Perinci::Access->new(%args);
    }
);
has common_opts => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        my ($self) = @_;

        my %opts;

        # 'action=<subcommand>' can be used to override --help (or
        # --subcommands, --version) if one of function arguments happens to be
        # 'help', 'subcommands', or 'version'. currently this is deliberately(?)
        # underdocumented.
        $opts{action} = {
            getopt  => "action=s",
            handler => sub {
                if ($_[1] eq 'subcommand') {
                    $self->{_force_subcommand} = 1;
                }
            },
        };

        $opts{version} = {
            getopt  => "version|v",
            usage   => N__("--version (or -v)"),
            summary => N__("Show version"),
            show_in_options => sub { $ENV{VERBOSE} },
            handler => sub {
                $self->_err("'url' not set, required for --version")
                    unless $self->url;
                unshift @{$self->{_actions}}, 'version';
                $self->{_check_required_args} = 0;
            },
        };

        $opts{help} = {
            getopt  => "help|h|?",
            usage   => N__("--help (or -h, -?) (--verbose)"),
            summary => N__("Display this help message"),
            show_in_options => sub { $ENV{VERBOSE} },
            handler => sub {
                unshift @{$self->{_actions}}, 'help';
                $self->{_check_required_args} = 0;
            },
            order   => 0, # high
        };

        $opts{format} = {
            getopt  => "format=s",
            summary => N__("Choose output format, e.g. json, text"),
            handler => sub {
                $self->format_set(1);
                $self->format($_[1]);
            },
        };

        $opts{format_options} = {
            getopt  => "format-options=s",
            summary => N__("Pass options to formatter"),
            handler => sub {
                $self->format_options_set(1);
                $self->format_options(__json_decode($_[1]));
            },
        };

        if ($self->subcommands) {
            $opts{subcommands} = {
                getopt  => "subcommands",
                usage   => N__("--subcommands"),
                show_in_usage => sub {
                    !$self->{_subcommand};
                },
                show_in_options => sub {
                    $ENV{VERBOSE} && !$self->{_subcommand};
                },
                show_usage_in_help => sub {
                    my $self = shift;
                },
                summary => N__("List available subcommands"),
                show_in_help => 0,
                handler => sub {
                    unshift @{$self->{_actions}}, 'subcommands';
                    $self->{_check_required_args} = 0;
                },
            };
        }

        if (defined $self->default_subcommand) {
            # 'cmd=SUBCOMMAND_NAME' can be used to select other subcommands when
            # default_subcommand is in effect.
            $opts{cmd} = {
                getopt  => "cmd=s",
                handler => sub {
                    $self->{_selected_subcommand} = $_[1];
                },
            };
        }

        # convenience for Log::Any::App-using apps
        if ($self->log_any_app) {
            # since the cmdline opts is consumed, Log::Any::App doesn't see
            # this. we currently work around this via setting env.
            for my $o (qw/quiet verbose debug trace/) {
                $opts{$o} = {
                    getopt  => $o,
                    summary => N__("Set log level to $o"),
                    handler => sub {
                        $ENV{uc $o} = 1;
                    },
                };
            }
            $opts{log_level} = {
                getopt  => "log-level=s",
                summary => N__("Set log level"),
                handler => sub {
                    $ENV{LOG_LEVEL} = $_[1];
                },
            };
        }

        if ($self->undo) {
            $opts{history} = {
                category => 'Undo options',
                getopt  => 'history',
                summary => N__('List actions history'),
                handler => sub {
                    unshift @{$self->{_actions}}, 'history';
                    $self->{_check_required_args} = 0;
                },
            };
            $opts{clear_history} = {
                category => 'Undo options',
                getopt  => "clear-history",
                summary => N__('Clear actions history'),
                handler => sub {
                    unshift @{$self->{_actions}}, 'clear_history';
                    $self->{_check_required_args} = 0;
                },
            };
            $opts{undo} = {
                category => 'Undo options',
                getopt  => 'undo',
                summary => N__('Undo previous action'),
                handler => sub {
                    unshift @{$self->{_actions}}, 'undo';
                    #$self->{_tx_id} = $_[1];
                    $self->{_check_required_args} = 0;
                },
            };
            $opts{redo} = {
                category => 'Undo options',
                getopt  => 'redo',
                summary => N__('Redo previous undone action'),
                handler => sub {
                    unshift @{$self->{_actions}}, 'redo';
                    #$self->{_tx_id} = $_[1];
                    $self->{_check_required_args} = 0;
                },
            };
        }

        \%opts;
    },
);
has action_metadata => (
    is => 'rw',
    default => sub {
        +{
            clear_history => {
            },
            help => {
                default_log => 0,
                use_utf8 => 1,
            },
            history => {
            },
            subcommands => {
                default_log => 0,
                use_utf8 => 1,
            },
            redo => {
            },
            subcommand => {
            },
            undo => {
            },
            version => {
                default_log => 0,
                use_utf8 => 1,
            },
        },
    },
);

sub __json_decode {
    require JSON;
    state $json = do { JSON->new->allow_nonref };
    $json->decode(shift);
}

sub _err {
    my $self = shift;
    my $msg = shift; $msg .= "\n" unless $msg =~ /\n\z/;
    die $self->_color('error_label', "ERROR: ") . $msg;
}

sub _program_and_subcommand_name {
    my $self = shift;
    my $res = $self->program_name . " " . ($self->{_subcommand}{name} // "");
    $res =~ s/\s+$//;
    $res;
}

sub BUILD {
    my ($self, $args) = @_;

    unless ($ENV{COMP_LINE}) {
        # pick default color theme and set it
        my $ct = $self->{color_theme} // $ENV{PERINCI_CMDLINE_COLOR_THEME};
        if (!$ct) {
            if ($self->use_color) {
                my $bg = $self->detect_terminal->{default_bgcolor} // '';
                $ct = 'Default::default' .
                    ($bg eq 'ffffff' ? '_whitebg' : '');
            } else {
                $ct = 'Default::no_color';
            }
        }
        $self->color_theme($ct);
    }
}

sub format_result {
    require Perinci::Result::Format;

    my $self = shift;
    my $res  = $self->{_res};
    return unless $res;

    my $resmeta = $res->[3] // {};
    unless ($resmeta->{"cmdline.display_result"} // 1) {
        $res->[2] = undef;
        return;
    }

    my $format = $self->format_set ?
        $self->format :
            $self->{_meta}{"x.perinci.cmdline.default_format"} // $self->format;
    $self->_err("Unknown output format '$format', please choose one of: ".
        join(", ", sort keys(%Perinci::Result::Format::Formats)))
            unless $Perinci::Result::Format::Formats{$format};
    if ($self->format_options_set) {
        $res->[3]{result_format_options} = $self->format_options;
        $resmeta = $res->[3];
    }

    if ($resmeta->{is_stream}) {
        $log->tracef("Result is a stream");
    } else {
        $log->tracef("Formatting output with %s", $format);
        $self->{_fres} = Perinci::Result::Format::format(
            $self->{_res}, $format);
    }
}

# format array item as row
sub format_row {
    require Data::Format::Pretty::Console;
    state $dfpc = Data::Format::Pretty::Console->new({interactive=>0});

    my ($self, $row) = @_;
    my $ref = ref($row);
    # we catch common cases to be faster (avoid dfpc's structure identification)
    if (!$ref) {
        # simple scalar
        return ($row // "") . "\n";
    } elsif ($ref eq 'ARRAY' && !(grep {ref($_)} @$row)) {
        # an array of scalars
        return join("\t", map { $dfpc->_format_cell($_) } @$row) . "\n";
    } else {
        # otherwise, just feed it to dfpc
        return $dfpc->_format($row);
    }
}

sub display_result {
    require File::Which;

    my $self = shift;

    my $res  = $self->{_res};
    return unless $res;

    my $resmeta = $res->[3] // {};

    my $handle;
    {
        if ($resmeta->{"cmdline.page_result"}) {
            my $pager = $resmeta->{"cmdline.pager"} //
                $ENV{PAGER};
            unless (defined $pager) {
                $pager = "less -FRSX" if File::Which::which("less");
            }
            unless (defined $pager) {
                $pager = "more" if File::Which::which("more");
            }
            unless (defined $pager) {
                $self->_err("Can't determine PAGER");
            }
            last unless $pager; # ENV{PAGER} can be set 0/'' to disable paging
            $log->tracef("Paging output using %s", $pager);
            open $handle, "| $pager";
        }
    }
    $handle //= \*STDOUT;

    if ($resmeta->{is_stream}) {
        $self->_err("Can't format stream as " . $self->format .
                        ", please use --format text")
            unless $self->format =~ /^text/;
        my $r = $res->[2];
        if (ref($r) eq 'GLOB') {
            while (!eof($r)) {
                print $handle ~~<$r>;
            }
        } elsif (blessed($r) && $r->can('getline') && $r->can('eof')) {
            # IO::Handle-like object
            while (!$r->eof) {
                print $r->getline;
            }
        } elsif (ref($r) eq 'ARRAY') {
            # tied array
            while (~~(@$r) > 0) {
                print $self->format_row(shift(@$r));
            }
        } else {
            $self->_err("Invalid stream in result (not a glob/IO::Handle-like ".
                            "object/(tied) array)\n");
        }
    } else {
        print $handle $self->{_fres} // "";
    }
}

sub get_subcommand {
    my ($self, $name) = @_;

    my $scs = $self->subcommands;
    return undef unless $scs;

    if (reftype($scs) eq 'CODE') {
        return $scs->($self, name=>$name);
    } else {
        return $scs->{$name};
    }
}

sub list_subcommands {
    my ($self) = @_;
    state $cached;
    return $cached if $cached;

    my $scs = $self->subcommands;
    my $res;
    if ($scs) {
        if (reftype($scs) eq 'CODE') {
            $scs = $scs->($self);
            $self->_err("Subcommands code didn't return a hashref")
                unless ref($scs) eq 'HASH';
        }
        $res = $scs;
    } else {
        $res = {};
    }
    $cached = $res;
}

sub run_subcommands {
    my ($self) = @_;

    if (!$self->subcommands) {
        say __("There are no subcommands") . ".";
        return 0;
    }

    my $subcommands = $self->list_subcommands;

    # XXX get summary from Riap if not exist, but this results in multiple Riap
    # requests.

    my %percat_subc; # (cat1 => {subcmd1=>..., ...}, ...)
    while (my ($scn, $sc) = each %$subcommands) {
        my $cat = "";
        for my $tag (@{$sc->{tags} // []}) {
            my $tn = ref($tag) ? $tag->{name} : $tag;
            next unless $tn =~ /^category:(.+)/;
            $cat = $1;
            last;
        }
        $percat_subc{$cat}       //= {};
        $percat_subc{$cat}{$scn}   = $sc;
    }
    my $has_many_cats = scalar(keys %percat_subc) > 1;

    my $i = 0;
    for my $cat (sort keys %percat_subc) {
        if ($has_many_cats) {
            $self->_help_add_heading(
                __x("{category} subcommands",
                    category => ucfirst($cat) || __("main")));
        }
        my $subc = $percat_subc{$cat};
        for my $scn (sort keys %$subc) {
            my $sc = $subc->{$scn};
            my $summary = rimeta($sc)->langprop("summary");
            $self->_help_add_row(
                [$self->_color('program_name', $scn), $summary],
                {column_widths=>[-17, -40], indent=>1});
        }
    }
    $self->_help_draw_curtbl;

    0;
}

sub run_version {
    my ($self) = @_;

    my $url = $self->{_subcommand} && $self->{_subcommand}{url} ?
        $self->{_subcommand}{url} : $self->url;
    my $res = $self->_pa->request(meta => $url);
    my $ver;
    if ($res->[0] == 200) {
        $ver = $res->[2]{entity_v} // "?";
    } else {
        $log->warnf("Can't request 'meta' action on %s: %d - %s",
                    $url, $res->[0], $res->[1]);
        $ver = '?';
    }

    say __x(
        "{program} version {version}",
        program => $self->_color('program_name',
                                 $self->_program_and_subcommand_name),
        version => $self->_color('emphasis', $ver));
    {
        no strict 'refs';
        say "  ", __x(
            "{program} version {version}",
            program => $self->_color('emphasis', "Perinci::CmdLine"),
            version => $self->_color('emphasis',
                                     $Perinci::CmdLine::VERSION || "dev"));
    }

    0;
}

sub _add_slashes {
    my ($a) = @_;
    $a =~ s!([^A-Za-z0-9,+._/:-])!\\$1!g;
    $a;
}

sub run_completion {
    # Perinci::Sub::Complete already required by run()

    my ($self) = @_;

    my $sc = $self->{_subcommand};
    my $words = $self->{_comp_parse_res}{words};
    my $cword = $self->{_comp_parse_res}{cword};
    my $word  = $words->[$cword] // "";

    # determine whether we should complete function arg names/values or just
    # top-level opts + subcommands name
    my $do_arg;
    {
        if (!$self->subcommands) {
            $log->trace("do_arg because single command");
            $do_arg++; last;
        }

        my $scn = $sc->{name} // "";

        # whether user typed 'blah blah ^' or 'blah blah^'
        my $space_typed = !defined($word);

        # e.g: spanel delete-account ^
        if ($self->subcommands && $cword > 0 && $space_typed) {
            $log->trace("do_arg because last word typed (+space) is ".
                            "subcommand name");
            $do_arg++; last;
        }

        # e.g: spanel delete-account --format=yaml --acc^
        if ($cword > 0 && !$space_typed && $word ne $scn) {
            $log->trace("do_arg because subcommand name has been typed ".
                            "in past words");
            $do_arg++; last;
        }

        $log->tracef("not do_arg, cword=%d, words=%s, scn=%s, space_typed=%s",
                     $cword, $words, $scn, $space_typed);
    }

    my @top_opts; # contain --help, -h, etc.
    for my $o (keys %{{@{ $self->{_go_specs_common} }}}) {
        $o =~ s/^--//;
        $o =~ s/=.+$//;
        my @o = split /\|/, $o;
        for (@o) { push @top_opts, length > 1 ? "--$_" : "-$_" }
    }

    my $res;
    if ($do_arg) {
        $log->trace("Completing subcommand argument names & values ...");

        # remove subcommand name and general options from words so it doesn't
        # interfere with matching function args
        my $i = 0;
        while ($i < @$words) {
            if ($words->[$i] ~~ @top_opts ||
                    (defined($self->{_scn_in_argv}) &&
                         $words->[$i] eq $self->{_scn_in_argv})) {
                splice @$words, $i, 1;
                $cword-- unless $cword <= $i;
                next;
            } else {
                $i++;
            }
        }
        $log->tracef("cleaned words=%s, cword=%d", $words, $cword);

        # convert @getopts' ('help|h|?' => ..., ...) to ['--help', '-h', '-?',
        # ...]. XXX this should be moved to another module to remove
        # duplication, as Perinci::Sub::GetArgs::Argv also does something
        # similar.
        my $common_opts = [];
        for my $k (keys %{{@{ $self->{_go_specs_common} }}}) {
            $k =~ s/^--?//;
            $k =~ s/^([\w?-]+(?:\|[\w?-]+)*)(?:\W.*)?/$1/;
            for (split /\|/, $k) {
                push @$common_opts, (length == 1 ? "-$_" : "--$_");
            }
        }

        my $rres = $self->_pa->request(meta => $sc->{url});
        if ($rres->[0] != 200) {
            $log->debug("Can't get meta for completion: $res->[0] - $res->[1]");
            $res = [];
            goto DISPLAY_RES;
        }
        my $meta = $rres->[2];

        my $arg_completer = $self->custom_arg_completer;
        $arg_completer //= sub {
            my $rres = $self->_pa->request(complete_arg_val => $sc->{url});
            return undef unless $rres->[0] == 20;
            $rres->[2];
        };

        $res = Perinci::Sub::Complete::shell_complete_arg(
            meta=>$meta, words=>$words, cword=>$cword,
            common_opts => $common_opts,
            custom_completer=>$self->custom_completer,
            custom_arg_completer => $arg_completer,
        );

    } else {
        $log->trace("Completing top-level options + subcommand name ...");
        my @ary;
        push @ary, @top_opts;
        my $scs = $self->list_subcommands;
        push @ary, keys %$scs;
        $res = Perinci::Sub::Complete::complete_array(
            word=>$word, array=>\@ary,
        );
    }

  DISPLAY_RES:
    # display completion result for bash
    print map {_add_slashes($_), "\n"} grep {defined} @$res;
    0;
}

# some common opts can be added only after we get the function metadata
sub _add_common_opts_after_meta {
    my $self = shift;

    if (risub($self->{_meta})->can_dry_run) {
        $self->common_opts->{dry_run} = {
            getopt  => 'dry-run',
            summary => "Run in simulation mode (also via DRY_RUN=1)",
            handler => sub {
                $self->{_dry_run} = 1;
                $ENV{VERBOSE} = 1;
            },
        };
    }

    # update the cached getopt specs
    my @go_opts = $self->_gen_go_specs_from_common_opts;
    $self->{_go_specs_common} = \@go_opts;
}

sub _help_draw_curtbl {
    my $self = shift;

    if ($self->{_help_curtbl}) {
        print $self->{_help_curtbl}->draw;
        undef $self->{_help_curtbl};
    }
}

# ansitables are used to draw formatted help. they are 100% wide, with no
# borders (except space), but you can customize the number of columns (which
# will be divided equally)
sub _help_add_table {
    require Text::ANSITable;

    my ($self, %args) = @_;
    my $columns = $args{columns} // 1;

    $self->_help_draw_curtbl;
    my $t = Text::ANSITable->new;
    $t->border_style('Default::spacei_ascii');
    $t->cell_pad(0);
    if ($args{column_widths}) {
        for (0..$columns-1) {
            $t->set_column_style($_, width => $args{column_widths}[$_]);
        }
    } else {
        my $tw = $self->term_width;
        my $cw = int($tw/$columns)-1;
        $t->cell_width($cw);
    }
    $t->show_header(0);
    $t->column_wrap(0); # we'll do our own wrapping, before indent
    $t->columns([0..$columns-1]);

    $self->{_help_curtbl} = $t;
}

sub _help_add_row {
    my ($self, $row, $args) = @_;
    $args //= {};
    my $wrap    = $args->{wrap}   // 0;
    my $indent  = $args->{indent} // 0;
    my $columns = @$row;

    # start a new table if necessary
    $self->_help_add_table(
        columns=>$columns, column_widths=>$args->{column_widths})
        if !$self->{_help_curtbl} ||
            $columns != @{ $self->{_help_curtbl}{columns} };

    my $t = $self->{_help_curtbl};
    my $rownum = @{ $t->{rows} };

    $t->add_row($row);

    for (0..@{$t->{columns}}-1) {
        my %styles = (formats=>[]);
        push @{ $styles{formats} },
            [wrap=>{ansi=>1, mb=>1, width=>$t->{cell_width}-$indent*2}]
                if $wrap;
        push @{ $styles{formats} }, [lins=>{text=>"  " x $indent}]
            if $indent && $_ == 0;
        $t->set_cell_style($rownum, $_, \%styles);
    }
}

sub _help_add_heading {
    my ($self, $heading) = @_;
    $self->_help_add_row([$self->_color('heading', $heading)]);
}

sub _color {
    my ($self, $color_name, $text) = @_;
    my $color_code = $color_name ?
        $self->get_theme_color_as_ansi($color_name) : "";
    my $reset_code = $color_code ? "\e[0m" : "";
    "$color_code$text$reset_code";
}

sub help_section_summary {
    my ($self, %opts) = @_;

    my $summary = rimeta($self->{_help_meta})->langprop("summary");
    return unless $summary;

    my $name = $self->_program_and_subcommand_name;
    my $ct = join(
        "",
        $self->_color('program_name', $name),
        ($name && $summary ? ' - ' : ''),
        $summary // "",
    );
    $self->_help_add_row([$ct], {wrap=>1});
}

sub _usage_args {
    my $self = shift;

    my $m = $self->{_help_meta};
    return "" unless $m;
    my $aa = $m->{args};
    return "" unless $aa;

    # arguments with pos defined
    my @a = sort { $aa->{$a}{pos} <=> $aa->{$b}{pos} }
        grep { defined($aa->{$_}{pos}) } keys %$aa;
    my $res = "";
    for (@a) {
        $res .= " ";
        my $label = lc($_);
        $res .= $aa->{$_}{req} ? "<$label>" : "[$label]";
        $res .= " ..." if $aa->{$_}{greedy};
        last if $aa->{$_}{greedy};
    }
    $res;
}

sub help_section_usage {
    my ($self, %opts) = @_;

    my $co = $self->common_opts;
    my @con = grep {
        my $cov = $co->{$_};
        my $show = $cov->{show_in_usage} // 1;
        for ($show) { if (ref($_) eq 'CODE') { $_ = $_->($self) } }
        $show;
    } sort {
        ($co->{$a}{order}//1) <=> ($co->{$b}{order}//1) || $a cmp $b
    } keys %$co;

    my $pn = $self->_color('program_name', $self->_program_and_subcommand_name);
    my $ct = "";
    for my $con (@con) {
        my $cov = $co->{$con};
        next unless $cov->{usage};
        $ct .= ($ct ? "\n" : "") . $pn . " " . __($cov->{usage});
    }
    if ($self->subcommands && !$self->{_subcommand}) {
        if (defined $self->default_subcommand) {
            $ct .= ($ct ? "\n" : "") . $pn .
                " " . __("--cmd=<other-subcommand> [options]");
        } else {
            $ct .= ($ct ? "\n" : "") . $pn .
                " " . __("<subcommand> [options]");
        }
    } else {
            $ct .= ($ct ? "\n" : "") . $pn .
                " " . __("[options]"). $self->_usage_args;
    }
    $self->_help_add_heading(__("Usage"));
    $self->_help_add_row([$ct], {indent=>1});
}

sub help_section_options {
    require SHARYANTO::Getopt::Long::Util;

    my ($self, %opts) = @_;
    my $verbose = $opts{verbose};
    my $info = $self->{_help_info};
    my $meta = $self->{_help_meta};
    my $args_p = $meta->{args};
    my $sc = $self->subcommands;

    # stored gathered options by category, e.g. $catopts{"Common options"} (an
    # array containing options)
    my %catopts;

    my $t_opts = __("Options");
    my $t_copts = __("Common options");

    # gather common opts
    my $co = $self->common_opts;
    my @con = grep {
        my $cov = $co->{$_};
        my $show = $cov->{show_in_options} // 1;
        for ($show) { if (ref($_) eq 'CODE') { $_ = $_->($self) } }
        $show;
    } sort {
        ($co->{$a}{order}//1) <=> ($co->{$b}{order}//1) || $a cmp $b
    } keys %$co;
    for my $con (@con) {
        my $cov = $co->{$con};
        my $cat = $cov->{category} ? __($cov->{category}) :
            ($sc ? $t_copts : $t_opts);
        my $go = $cov->{getopt};
        push @{ $catopts{$cat} }, {
            getopt=>SHARYANTO::Getopt::Long::Util::gospec2human($cov->{getopt}),
            summary=> $cov->{summary} ? __($cov->{summary}) : "",
        };
    }

    # gather function opts (XXX: categorize according to tags)
    if ($info && $info->{type} eq 'function' && $args_p && %$args_p) {
        for my $an (sort {
            ($args_p->{$a}{pos} // 99) <=> ($args_p->{$b}{pos} // 99) ||
                $a cmp $b
            } keys %$args_p) {
            my $a = $args_p->{$an};
            my $s = $a->{schema} || [any=>{}];
            my $got = Perinci::ToUtil::sah2human_short($s);
            my $ane = $an; $ane =~ s/_/-/g; $ane =~ s/\W/-/g;
            my $summary = rimeta($a)->langprop("summary");

            my $suf = "";
            if ($s->[0] eq 'bool') {
                $got = undef;
                if ($s->[1]{default}) {
                    $ane = "no$ane";
                    my $negsummary = rimeta($a)->langprop(
                        "x.perinci.cmdline.negative_summary");
                    $summary = $negsummary if $negsummary;
                } elsif (defined $s->[1]{default}) {
                    #$ane = $ane;
                } else {
                    $ane = "[no]$ane";
                }
            } elsif ($s->[0] eq 'float' || $s->[0] eq 'num') {
                $ane .= "=f";
            } elsif ($s->[0] eq 'int') {
                $ane .= "=i";
            } elsif ($s->[0] eq 'hash' || $s->[0] eq 'array') {
                $suf = "-json";
                $ane = "$ane-json=val";
            } else {
                $ane .= "=s";
            }

            # add aliases which does not have code
            for my $al0 (keys %{ $a->{cmdline_aliases} // {}}) {
                my $alspec = $a->{cmdline_aliases}{$al0};
                next if $alspec->{code};
                my $al = $al0; $al =~ s/_/-/g;
                $al = length($al) > 1 ? "--$al" : "-$al";
                $ane .= ", $al$suf";
            }

            my $def = defined($s->[1]{default}) && $s->[0] ne 'bool' ?
                " (default: ".dump1($s->[1]{default}).")" : "";
            my $src = $a->{cmdline_src} // "";
            my $in;
            if ($s->[1]{in} && @{ $s->[1]{in} }) {
                $in = dump1($s->[1]{in});
            }

            my $cat;
            for my $tag (@{ $a->{tags} // []}) {
                my $tn = ref($tag) ? $tag->{name} : $tag;
                next unless $tn =~ /^category:(.+)/;
                $cat = $1;
                last;
            }
            if ($cat) {
                $cat = __x("{category} options", category=>ucfirst($cat));
            } else {
                $cat = $t_opts;
            }

            push @{ $catopts{$cat} }, {
                getopt => "--$ane",
                getopt_type => $got,
                getopt_note =>join(
                    "",
                    ($a->{req} ? " (" . __("required") . ")" : ""),
                    (defined($a->{pos}) ? " (" .
                         __x("or as argument #{index}",
                            index => ($a->{pos}+1).($a->{greedy} ? "+":"")).")":""),
                    ($src eq 'stdin' ?
                         " (" . __("from stdin") . ")" : ""),
                    ($src eq 'stdin_or_files' ?
                         " (" . __("from stdin/files") . ")" : ""),
                    $def
                ),
                req => $a->{req},
                summary => $summary,
                description => rimeta($a)->langprop("description"),
                in => $in,
            };

            # add aliases which have code as separate options
            for my $al0 (keys %{ $a->{cmdline_aliases} // {}}) {
                my $alspec = $a->{cmdline_aliases}{$al0};
                next unless $alspec->{code};
                push @{ $catopts{$cat} }, {
                    getopt => length($al0) > 1 ? "--$al0" : "-$al0",
                    getopt_type => $got,
                    getopt_note => undef,
                    #req => $a->{req},
                    summary => rimeta($alspec)->langprop("summary"),
                    description => rimeta($alspec)->langprop("description"),
                    #in => $in,
                };
            }

        }
    }

    # output gathered options
    for my $cat (sort keys %catopts) {
        $self->_help_add_heading($cat);
        my @opts = sort {
            my $va = $a->{getopt};
            my $vb = $b->{getopt};
            for ($va, $vb) { s/^--(\[no\])?// }
            $va cmp $vb;
        } @{$catopts{$cat}};
        if ($verbose) {
            for my $o (@opts) {
                my $ct = $self->_color('option_name', $o->{getopt}) .
                    ($o->{getopt_type} ? " [$o->{getopt_type}]" : "").
                        ($o->{getopt_note} ? $o->{getopt_note} : "");
                $self->_help_add_row([$ct], {indent=>1});
                if ($o->{in} || $o->{summary} || $o->{description}) {
                    my $ct = "";
                    $ct .= ($ct ? "\n\n":"").ucfirst(__("value in")).
                        ": $o->{in}" if $o->{in};
                    $ct .= ($ct ? "\n\n":"")."$o->{summary}." if $o->{summary};
                    $ct .= ($ct ? "\n\n":"").$o->{description}
                        if $o->{description};
                    $self->_help_add_row([$ct], {indent=>2, wrap=>1});
                }
            }
        } else {
            # for compactness, display in columns
            my $tw = $self->term_width;
            my $columns = int($tw/40); $columns = 1 if $columns < 1;
            while (1) {
                my @row;
                for (1..$columns) {
                    last unless @opts;
                    my $o = shift @opts;
                    push @row, $self->_color('option_name', $o->{getopt}) .
                        #($o->{getopt_type} ? " [$o->{getopt_type}]" : "") .
                            ($o->{getopt_note} ? $o->{getopt_note} : "");
                }
                last unless @row;
                for (@row+1 .. $columns) { push @row, "" }
                $self->_help_add_row(\@row, {indent=>1});
            }
        }
    }
}

sub help_section_subcommands {
    my ($self, %opts) = @_;

    my $scs = $self->subcommands;
    return unless $scs && !$self->{_subcommand};

    my @scs = sort keys %$scs;
    my @shown_scs;
    for my $scn (@scs) {
        my $sc = $scs->{$scn};
        next unless $sc->{show_in_help} // 1;
        $sc->{name} = $scn;
        push @shown_scs, $sc;
    }

    # for help_section_hints
    my $some_not_shown = @scs > @shown_scs;
    $self->{_some_subcommands_not_shown_in_help} = 1 if $some_not_shown;

    $self->_help_add_heading(
        $some_not_shown ? __("Popular subcommands") : __("Subcommands"));

    # in compact mode, we try to not exceed one screen, so show long mode only
    # if there are a few subcommands.
    my $long_mode = $opts{verbose} || @shown_scs < 12;
    if ($long_mode) {
        for (@shown_scs) {
            my $summary = rimeta($_)->langprop("summary");
            $self->_help_add_row(
                [$self->_color('program_name', $_->{name}), $summary],
                {column_widths=>[-17, -40], indent=>1});
        }
    } else {
        # for compactness, display in columns
        my $tw = $self->term_width;
        my $columns = int($tw/25); $columns = 1 if $columns < 1;
            while (1) {
                my @row;
                for (1..$columns) {
                    last unless @shown_scs;
                    my $sc = shift @shown_scs;
                    push @row, $sc->{name};
                }
                last unless @row;
                for (@row+1 .. $columns) { push @row, "" }
                $self->_help_add_row(\@row, {indent=>1});
            }

    }
}

sub help_section_hints {
    my ($self, %opts) = @_;
    my @hints;
    unless ($opts{verbose}) {
        push @hints, N__("For more complete help, use '--help --verbose'");
    }
    if ($self->{_some_subcommands_not_shown_in_help}) {
        push @hints,
            N__("To see all available subcommands, use '--subcommands'");
    }
    return unless @hints;

    $self->_help_add_row(
        [join(" ", map { __($_)."." } @hints)], {wrap=>1});
}

sub help_section_description {
    my ($self, %opts) = @_;

    my $desc = rimeta($self->{_help_meta})->langprop("description") //
        $self->description;
    return unless $desc;

    $self->_help_add_heading(__("Description"));
    $self->_help_add_row([$desc], {wrap=>1, indent=>1});
}

sub help_section_examples {
    my ($self, %opts) = @_;

    my $verbose = $opts{verbose};
    my $meta = $self->{_help_meta};
    my $egs = $meta->{examples};
    return unless $egs && @$egs;

    $self->_help_add_heading(__("Examples"));
    my $pn = $self->_color('program_name', $self->_program_and_subcommand_name);
    for my $eg (@$egs) {
        my $argv;
        my $ct;
        if (defined($eg->{src})) {
            # we only show shell command examples
            if ($eg->{src_plang} =~ /^(sh|bash)$/) {
                $ct = $eg->{src};
            } else {
                next;
            }
        } else {
            require String::ShellQuote;
            if ($eg->{argv}) {
                $argv = $eg->{argv};
            } else {
                require Perinci::Sub::ConvertArgs::Argv;
                my $res = Perinci::Sub::ConvertArgs::Argv::convert_args_to_argv(
                    args => $eg->{args}, meta => $meta);
                $self->_err("Can't convert args to argv: $res->[0] - $res->[1]")
                    unless $res->[0] == 200;
                $argv = $res->[2];
            }
            $ct = $pn;
            for my $arg (@$argv) {
                $arg = String::ShellQuote::shell_quote($arg);
                if ($arg =~ /^-/) {
                    $ct .= " ".$self->_color('option_name', $arg);
                } else {
                    $ct .= " $arg";
                }
            }
        }
        $self->_help_add_row([$ct], {indent=>1});
        if ($verbose) {
            $ct = "";
            my $summary = rimeta($eg)->langprop('summary');
            if ($summary) { $ct .= "$summary." }
            my $desc = rimeta($eg)->langprop('description');
            if ($desc) { $ct .= "\n\n$desc" }
            $self->_help_add_row([$ct], {indent=>2}) if $ct;
        }
    }
}

sub help_section_links {
    # not yet
}

sub run_help {
    my ($self) = @_;

    my $verbose = $ENV{VERBOSE} // 0;
    my %opts = (verbose=>$verbose);

    # get function metadata first
    my $sc = $self->{_subcommand};
    my $url = $sc ? $sc->{url} : $self->url;
    if ($url) {
        my $res = $self->_pa->request(info => $url);
        $self->_err("Can't info '$url': $res->[0] - $res->[1]")
            unless $res->[0] == 200;
        $self->{_help_info} = $res->[2];
        $res = $self->_pa->request(meta => $url);
        $self->_err("Can't meta '$url': $res->[0] - $res->[1]")
            unless $res->[0] == 200;
        $self->{_help_meta} = $res->[2];
    }

    # determine which help sections should we generate
    my @hsects;
    if ($verbose) {
        @hsects = (
            'summary',
            'usage',
            'subcommands',
            'examples',
            'description',
            'options',
            'links',
            'hints',
        );
    } else {
        @hsects = (
            'summary',
            'usage',
            'subcommands',
            'examples',
            'options',
            'hints',
        );
    }

    for my $s (@hsects) {
        my $meth = "help_section_$s";
        $log->tracef("=> $meth(%s)", \%opts);
        $self->$meth(%opts);
    }
    $self->_help_draw_curtbl;
    0;
}

my ($ph1, $ph2); # patch handles
sub _setup_progress_output {
    my $self = shift;

    if ($ENV{PROGRESS} // (-t STDOUT)) {
        require Progress::Any::Output;
        Progress::Any::Output->set("TermProgressBarColor");
        my $out = $Progress::Any::outputs{''}[0];
        # we need to patch the logger adapters so it won't interfere with
        # progress meter's output
        require Monkey::Patch::Action;
        $ph1 = Monkey::Patch::Action::patch_package(
            'Log::Log4perl::Appender::Screen', 'log',
            'replace', sub {
                my ($self, %params) = @_;

                my $msg = $params{message};
                $msg =~ s/\n//g;

                # clean currently displayed progress bar first
                if ($out->{lastlen}) {
                    print
                        "\b" x $out->{lastlen},
                            " " x $out->{lastlen},
                                "\b" x $out->{lastlen};
                    undef $out->{lastlen};
                }

                say $msg;
            },
        ) if defined &{"Log::Log4perl::Appender::Screen::log"};
        $ph2 = Monkey::Patch::Action::patch_package(
            'Log::Log4perl::Appender::ScreenColoredLevels', 'log',
            'replace', sub {
                my ($self, %params) = @_;
                # BEGIN copy-paste'ish from ScreenColoredLevels.pm
                my $msg = $params{message};
                $msg =~ s/\n//g;
                if (my $color=$self->{color}->{$params{log4p_level}}) {
                    $msg = Term::ANSIColor::colored($msg, $color);
                }
                # END copy-paste'ish

                # clean currently displayed progress bar first
                if ($out->{lastlen}) {
                    print
                        "\b" x $out->{lastlen},
                            " " x $out->{lastlen},
                                "\b" x $out->{lastlen};
                    undef $out->{lastlen};
                }

                # XXX duplicated code above, perhaps move this to
                # TermProgressBarColor's clean_bar() or something

                say $msg;
            }
        ) if defined &{"Log::Log4perl::Appender::ScreenColoredLevels::log"};
    }
}

sub run_subcommand {
    require File::Which;

    my ($self) = @_;
    my $sc = $self->{_subcommand};
    my %fargs = %{$self->{_args} // {}};
    $fargs{-cmdline} = $self if $sc->{pass_cmdline_object} //
        $self->pass_cmdline_object;

    my $tx_id;

    my $using_tx = !$self->{_dry_run} && $self->undo && ($sc->{undo} // 1);

    if ($using_tx) {
        require UUID::Random;
        $tx_id = UUID::Random::generate();
        $tx_id =~ s/-.+//; # 32bit suffices for small number of txs
        my $summary = join(" ", @{ $self->{_orig_argv} });
        my $res = $self->_pa->request(
            begin_tx => "/", {tx_id=>$tx_id, summary=>$summary});
        if ($res->[0] != 200) {
            $self->{_res} = [$res->[0],
                             "Can't start transaction '$tx_id': $res->[1]"];
            return 1;
        }
    }

    # setup output progress indicator
    state $setup_progress;
    if ($self->{_meta}{features}{progress}) {
        unless ($setup_progress) {
            $self->_setup_progress_output;
            $setup_progress++;
        }
    }

    # call function
    $self->{_res} = $self->_pa->request(
        call => $self->{_subcommand}{url},
        {args=>\%fargs, tx_id=>$tx_id, dry_run=>$self->{_dry_run}});
    $log->tracef("call res=%s", $self->{_res});

    # commit transaction (if using tx)
    if ($using_tx && $self->{_res}[0] =~ /\A(?:200|304)\z/) {
        my $res = $self->_pa->request(commit_tx => "/", {tx_id=>$tx_id});
        if ($res->[0] != 200) {
            $self->{_res} = [$res->[0],
                             "Can't commit transaction '$tx_id': $res->[1]"];
            return 1;
        }
    }

    my $resmeta = $self->{_res}[3] // {};
    if (defined $resmeta->{"cmdline.exit_code"}) {
        return $resmeta->{"cmdline.exit_code"};
    } else {
        return $self->{_res}[0] =~ /\A(?:200|304)\z/ ?
            0 : $self->{_res}[0] - 300;
    }
}

sub run_history {
    my $self = shift;
    my $res = $self->_pa->request(list_txs => "/", {detail=>1});
    $log->tracef("list_txs res=%s", $res);
    return 1 unless $res->[0] == 200;
    $res->[2] = [sort {($b->{tx_commit_time}//0) <=> ($a->{tx_commit_time}//0)}
                     @{$res->[2]}];
    my @txs;
    for my $tx (@{$res->[2]}) {
        next unless $tx->{tx_status} =~ /[CUX]/;
        push @txs, {
            id          => $tx->{tx_id},
            start_time  => $tx->{tx_start_time},
            commit_time => $tx->{tx_commit_time},
            status      => $tx->{tx_status} eq 'X' ? 'error' :
                $tx->{tx_status} eq 'U' ? 'undone' : '',
            summary     => $tx->{tx_summary},
        };
    }
    $self->{_res} = [200, "OK", \@txs];
    0;
}

sub run_clear_history {
    my $self = shift;
    $self->{_res} = $self->_pa->request(discard_all_txs => "/");
    $self->{_res}[0] == 200 ? 0 : 1;
}

sub run_undo {
    my $self = shift;
    $self->{_res} = $self->_pa->request(undo => "/");
    $self->{_res}[0] == 200 ? 0 : 1;
}

sub run_redo {
    my $self = shift;
    $self->{_res} = $self->_pa->request(redo => "/");
    $self->{_res}[0] == 200 ? 0 : 1;
}

sub _gen_go_specs_from_common_opts {
    my $self = shift;

    my @go_opts;
    my $co = $self->common_opts;
    for my $con (sort {
        ($co->{$a}{order}//1) <=> ($co->{$b}{order}//1) || $a cmp $b
    } keys %$co) {
        my $cov = $co->{$con};
        $self->_err("Invalid common option '$con': empty getopt")
            unless $cov->{getopt};
        push @go_opts, $cov->{getopt} => $cov->{handler};
    }

    @go_opts;
}

sub parse_common_opts {
    require Getopt::Long;

    $log->tracef("-> parse_common_opts()");
    my ($self) = @_;

    my @orig_ARGV = @ARGV;
    $self->{_orig_argv} = \@orig_ARGV;

    my @go_opts = $self->_gen_go_specs_from_common_opts;
    $self->{_go_specs_common} = \@go_opts;
    my $old_go_opts = Getopt::Long::Configure(
        "pass_through", "no_ignore_case", "no_getopt_compat");
    Getopt::Long::GetOptions(@go_opts);
    $log->tracef("result of GetOptions for common options: remaining argv=%s, ".
                     "actions=%s", \@ARGV, $self->{_actions});
    Getopt::Long::Configure($old_go_opts);

    if ($self->{_force_subcommand}) {
        @ARGV = @orig_ARGV;
    }

    $log->tracef("<- parse_common_opts()");
}

sub parse_subcommand_opts {
    require Perinci::Sub::GetArgs::Argv;

    my ($self) = @_;
    my $sc = $self->{_subcommand};
    return unless $sc && $sc->{url};
    $log->tracef("-> parse_subcommand_opts()");

    my $res = $self->_pa->request(meta=>$sc->{url});
    if ($res->[0] == 200) {
        # prefill arguments using 'args' from subcommand specification, if any
        $self->{_args} = {};
        if ($sc->{args}) {
            for (keys %{ $sc->{args} }) {
                $self->{_args}{$_} = $sc->{args}{$_};
            }
        }
    } else {
        $log->warnf("Can't get metadata from %s: %d - %s", $sc->{url},
                    $res->[0], $res->[1]);
        $log->tracef("<- parse_subcommand_opts() (bailed)");
        return;
    }
    my $meta = $res->[2];
    $self->{_meta} = $meta;
    $self->_add_common_opts_after_meta;

    # also set dry-run on environment
    do { $self->{_dry_run} = 1; $ENV{VERBOSE} = 1 } if $ENV{DRY_RUN};

    # parse argv
    $Perinci::Sub::GetArgs::Argv::_pa_skip_check_required_args = 1
        if $self->{_pa_skip_check_required_args};
    my $src_seen;
    my %ga_args = (
        argv                => \@ARGV,
        meta                => $meta,
        check_required_args => $self->{_check_required_args} // 1,
        allow_extra_elems   => 1,
        per_arg_json        => 1,
        per_arg_yaml        => 1,
        on_missing_required_args => sub {
            my %a = @_;
            my ($an, $aa, $as) = ($a{arg}, $a{args}, $a{spec});
            say "missing arg $an";
            my $src = $as->{cmdline_src};
            # fill with undef first, will be filled from other source
            $aa->{$an} = undef if $src && $as->{req};
        },
    );
    if ($self->{_force_subcommand}) {
        $ga_args{extra_getopts_before} = $self->{_go_specs_common};
    } else {
        $ga_args{extra_getopts_after}  = $self->{_go_specs_common};
    }
    $res = Perinci::Sub::GetArgs::Argv::get_args_from_argv(%ga_args);

    # We load Log::Any::App rather late here, to be able to customize level via
    # --debug, --dry-run, etc.
    unless ($ENV{COMP_LINE}) {
        my $do_log = $self->{_subcommand}{log_any_app};
        $do_log //= $ENV{LOG};
        $do_log //= $self->{action_metadata}{$self->{_actions}[0]}{default_log}
            if @{ $self->{_actions} };
        $do_log //= $self->log_any_app;
        $self->_load_log_any_app if $do_log;
    }

    $self->_err("Failed parsing arguments: $res->[0] - $res->[1]")
        unless $res->[0] == 200;
    for (keys %{ $res->[2] }) {
        $self->{_args}{$_} = $res->[2]{$_};
    }
    $log->tracef("result of GetArgs for subcommand: remaining argv=%s, args=%s".
                     ", actions=%s", \@ARGV, $self->{_args}, $self->{_actions});

    # handle cmdline_src
    if (!$ENV{COMP_LINE} && ($self->{_actions}[0] // "") eq 'subcommand') {
        my $args_p = $meta->{args} // {};
        my $stdin_seen;
        for my $an (sort keys %$args_p) {
            my $as = $args_p->{$an};
            my $src = $as->{cmdline_src};
            if ($src) {
                $self->_err(
                    "Invalid 'cmdline_src' value for argument '$an': $src")
                    unless $src =~ /\A(stdin|file|stdin_or_files)\z/;
                $self->_err(
                    "Sorry, argument '$an' is set cmdline_src=$src, but type ".
                        "is not 'str' or 'array', only those are supported now")
                    unless $as->{schema}[0] =~ /\A(str|array)\z/;
                if ($src =~ /stdin/) {
                    $self->_err("Only one argument can be specified ".
                                    "cmdline_src stdin/stdin_or_files")
                        if $stdin_seen++;
                }
                my $is_ary = $as->{schema}[0] eq 'array';
                if ($src eq 'stdin' || $src eq 'file' &&
                        ($self->{_args}{$an}//"") eq '-') {
                    $self->_err("Argument $an must be set to '-' which means ".
                                    "from stdin")
                        if defined($self->{_args}{$an}) &&
                            $self->{_args}{$an} ne '-';
                    $log->trace("Getting argument '$an' value from stdin ...");
                    $self->{_args}{$an} = $is_ary ? [<STDIN>] :
                        do { local $/; <STDIN> };
                } elsif ($src eq 'stdin_or_files') {
                    $log->trace("Getting argument '$an' value from ".
                                    "stdin_or_files ...");
                    $self->{_args}{$an} = $is_ary ? [<>] : do { local $/; <> };
                } elsif ($src eq 'file') {
                    next unless exists $self->{_args}{$an};
                    $self->_err("Please specify filename for argument '$an'")
                        unless defined $self->{_args}{$an};
                    $log->trace("Getting argument '$an' value from ".
                                    "file ...");
                    my $fh;
                    unless (open $fh, "<", $self->{_args}{$an}) {
                        $self->_err("Can't open file '$self->{_args}{$an}' ".
                                        "for argument '$an': $!")
                    }
                    $self->{_args}{$an} = $is_ary ? [<$fh>] :
                        do { local $/; <$fh> };
                }
            }
        }
    }
    $log->tracef("args after cmdline_src is processed: %s", $self->{_args});

    $log->tracef("<- _parse_subcommand_opts()");
}

# set $self->{_subcommand} for convenience, it can be taken from subcommands(),
# or, in the case of app with a single command, {name=>'', url=>$self->url()}.
sub _set_subcommand {
    my ($self) = @_;

    if ($self->subcommands) {
        my $scn;
        if (defined $self->{_selected_subcommand}) {
            $scn = $self->{_selected_subcommand};
        } elsif (defined $self->default_subcommand) {
            $scn = $self->default_subcommand;
        } elsif (@ARGV) {
            $scn = shift @ARGV;
            $self->{_scn_in_argv} = $scn;
        } else {
            goto L1;
        }
        my $sc = $self->get_subcommand($scn);
        unless ($sc) {
            if ($ENV{COMP_LINE}) {
                goto L1;
            } else {
                $self->_err(
                    "Unknown subcommand '$scn', use '".
                        $self->program_name.
                            " --subcommands' to list available subcommands");
            }
        }
        $self->{_subcommand} = $sc;
        $self->{_subcommand}{name} = $scn;
        if ($self->{_force_subcommand}) {
            unshift @{$self->{_actions}}, 'subcommand';
        } else {
            push @{$self->{_actions}}, 'subcommand';
        }
    } else {
        $self->{_subcommand} = {url=>$self->url, summary=>$self->summary};
        $self->{_subcommand}{name} = '';
        if ($self->{_force_subcommand}) {
            unshift @{$self->{_actions}}, 'subcommand';
        } else {
            push @{$self->{_actions}}, 'subcommand';
        }
    }
  L1:
    unshift @{$self->{_actions}}, 'completion' if $ENV{COMP_LINE};
    push @{$self->{_actions}}, 'help' if !@{$self->{_actions}};

    # unlogged, too early
    $log->tracef("actions=%s, subcommand=%s",
                 $self->{_actions}, $self->{_subcommand});
}

sub _load_log_any_app {
    my ($self) = @_;
    # Log::Any::App::init can already avoid being run twice, but we need to
    # check anyway to avoid logging starting message below twice.
    return if $self->{_log_any_app_loaded}++;
    require Log::Any::App;
    Log::Any::App::init();

    # we log this after we initialize Log::Any::App, since Log::Any::App might
    # not be loaded at all. yes, this means that this log message is printer
    # rather late and might not be the first message to be logged (see log
    # messages in run()) if user already loads Log::Any::App by herself.
    $self->{_original_argv} =
        $log->debugf("Program %s started with arguments: %s",
                     $0, $self->{_orig_argv});
}

sub run {
    my ($self) = @_;

    $log->trace("-> CmdLine's run()");

    #
    # workaround: detect (1) if we're being invoked for bash completion, get
    # @ARGV from parsing COMP_LINE/COMP_POINT instead, since @ARGV given by bash
    # is messed up / different
    #

    if ($ENV{COMP_LINE}) {
        require Perinci::Sub::Complete;
        my $res = Perinci::Sub::Complete::parse_shell_cmdline();
        @ARGV = @{ $res->{words} };
        $self->{_comp_parse_res} = $res; # store for run_completion()
    }

    #
    # set locale
    #
    {
        require POSIX;
        my $locale = $ENV{LANGUAGE} || $ENV{LANG};
        POSIX::setlocale(POSIX::LC_ALL(), $locale)
              or warn "Can't setlocale to $locale";
        require Locale::Messages;
        $ENV{OUTPUT_CHARSET} = 'UTF-8';
        Locale::Messages::bind_textdomain_filter(
            'Perinci-CmdLine' => \&Encode::decode_utf8);
    }

    $self->{_actions} = []; # first action will be tried first, then 2nd, ...

    #
    # parse common opts first so we can catch --help, --list, etc.
    #

    $self->parse_common_opts;

    #
    # find out which subcommand to run, store it in $self->{_subcommand}
    #

    $self->_set_subcommand();

    #
    # parse subcommand options, this is to give change to function arguments
    # like --help to be parsed into $self->{_args}
    #

    $self->parse_subcommand_opts unless $ENV{COMP_LINE};

    #
    # finally invoke the appropriate run_*() action method(s)
    #

    my $exit_code;
    while (@{$self->{_actions}}) {
        my $action = shift @{$self->{_actions}};

        unless ($ENV{COMP_LINE}) {
            # determine whether to binmode(STDOUT,":utf8")
            my $utf8 = $ENV{UTF8};
            if (!defined($utf8)) {
                my $am = $self->action_metadata->{$action};
                $utf8 //= $am->{use_utf8};
            }
            if (!defined($utf8) && $self->{_subcommand}) {
                $utf8 //= $self->{_subcommand}{use_utf8};
            }
            $utf8 //= $self->use_utf8;
            if ($utf8) {
                binmode(STDOUT, ":utf8");
            }
        }

        my $meth = "run_$action";
        $log->tracef("-> %s()", $meth);
        $exit_code = $self->$meth;
        $log->tracef("<- %s(), return=%s", $meth, $exit_code);
        last if defined $exit_code;
    }
    $self->format_result;
    $self->display_result;

    $log->tracef("<- CmdLine's run(), exit code=%s", $exit_code);
    if ($self->exit) {
        $log->debugf("Program ending with exit code %d", $exit_code);
        exit $exit_code;
    } else {
        return $exit_code;
    }
}

1;
# ABSTRACT: Rinci/Riap-based command-line application framework

=for Pod::Coverage ^(BUILD|run_.+|help_section_.+|format_result|format_row|display_result|get_subcommand|list_subcommands|parse_common_opts|parse_subcommand_opts|format_set|format_options|format_options_set)$

=head1 SYNOPSIS

In your command-line script:

 #!/usr/bin/perl
 use 5.010;
 use Log::Any '$log';
 use Perinci::CmdLine;

 our %SPEC;
 $SPEC{foo} = {
     v => 1.1,
     summary => 'Does foo to your computer',
     args => {
         bar => {
             summary=>'Barrr',
             req=>1,
             schema=>['str*', {in=>[qw/aa bb cc/]}],
         },
         baz => {
             summary=>'Bazzz',
             schema=>'str',
         },
     },
 };
 sub foo {
     my %args = @_;
     $log->debugf("Arguments are %s", \%args);
     [200, "OK", $args{bar} . ($args{baz} ? "and $args{baz}" : "")];
 }

 Perinci::CmdLine->new(url => '/main/foo')->run;

To run this program:

 % foo --help ;# display help message
 % LANG=id_ID foo --help ;# display help message in Indonesian
 % foo --version ;# display version
 % foo --bar aa ;# run function and display the result
 % foo --bar aa --debug ;# turn on debug output
 % foo --baz x  ;# fail because required argument 'bar' not specified

To do bash tab completion:

 % complete -C foo foo ;# can be put in ~/.bashrc
 % foo <tab> ;# completes to --help, --version, --bar, --baz and others
 % foo --b<tab> ;# completes to --bar and --baz
 % foo --bar <tab> ;# completes to aa, bb, cc

See also the L<peri-run> script which provides a command-line interface for
Perinci::CmdLine.


=head1 DESCRIPTION

Perinci::CmdLine is a command-line application framework. It parses command-line
options and dispatches to one of your specified Perl functions, passing the
command-line options and arguments to the function. It accesses functions via
L<Riap> protocol (using the L<Perinci::Access> Riap client library) so you can
access remote functions transparently. It utilizes L<Rinci> metadata in the code
so the amount of plumbing that you have to do is quite minimal. Basically most
of the time you just need to write your "business logic" in your function (along
with some metadata), and with a couple or several lines of script you have
created a command-line interface with the following features:

=over 4

=item * Command-line options parsing

Non-scalar arguments (array, hash, other nested) can also be passed as JSON or
YAML. For example, if the C<tags> argument is defined as 'array', then all of
below are equivalent:

 % mycmd --tags-yaml '[foo, bar, baz]'
 % mycmd --tags-yaml '["foo","bar","baz"]'
 % mycmd --tags foo --tags bar --tags baz

=item * Help message (utilizing information from metadata, supports translation)

 % mycmd --help
 % mycmd -h
 % mycmd -?

=item * Tab completion for bash (including completion from remote code)

 % complete -C mycmd mycmd
 % mycmd --he<tab> ; # --help
 % mycmd s<tab>    ; # sub1, sub2, sub3 (if those are the specified subcommands)
 % mycmd sub1 -<tab> ; # list the options available for sub1 subcommand

Support for other shell might be added in the future upon request.

=item * Undo/redo/history

If the function supports transaction (see L<Rinci::Transaction>,
L<Riap::Transaction>) the framework will setup transaction and provide command
to do undo (--undo) and redo (--redo) as well as seeing the undo/transaction
list (--history) and clearing the list (--clear-history).

=item * Version (--version, -v)

=item * List available subcommands (--list, -l)

=item * Configurable output format (--format, --format-options)

By default C<yaml>, C<json>, C<text>, C<text-simple>, C<text-pretty> are
recognized.

=back

Note that the each of the above command-line options (C<--help>, C<--version>,
etc) can be renamed or disabled.

This module uses L<Log::Any> and L<Log::Any::App> for logging. This module uses
L<Moo> for OO.


=head1 DISPATCHING

Below is the description of how the framework determines what action and which
function to call. (Currently lots of internal attributes are accessed directly,
this might be rectified in the future.)

B<Actions>. The C<_actions> attribute is an array which contains the list of
potential actions to choose, in order. It will then be filled out according to
the command-line options specified. For example, if C<--help> is specified,
C<help> action is shifted to the beginning of C<_actions>. Likewise for
C<--list>, etc. Finally, the C<subcommand> action (which means an action to call
our function) is added to this list. After we are finished filling out the
C<_actions> array, the first action is chosen by running a method called C<<
run_<ACTION> >>. For example if the chosen action is C<help>, C<run_help()> is
called. These C<run_*> methods must execute the action, display the output, and
return an exit code. Program will end with this exit code. A C<run_*> method can
choose to decline handling the action by returning undef, in which case the next
action will be tried, and so on until a defined exit code is returned.

B<The subcommand action and determining which subcommand (function) to call>.
The C<subcommand> action (implemented by C<run_subcommand()>) is the one that
actually does the real job, calling the function and displaying its result. The
C<_subcommand> attribute stores information on the subcommand to run, including
its Riap URL. If there are subcommands, e.g.:

 my $cmd = Perinci::CmdLine->new(
     subcommands => {
         sub1 => {
             url => '/MyApp/func1',
         },
         sub2 => {
             url => '/MyApp/func2',
         },
     },
 );

then which subcommand to run is determined by the command-line argument, e.g.:

 % myapp sub1 ...

then C<_subcommand> attribute will contain C<< {url=>'/MyApp/func1'} >>. When no
subcommand is specified on the command line, C<run_subcommand()> will decline
handling the action and returning undef, and the next action e.g. C<help> will
be executed. But if C<default_subcommand> attribute is set, C<run_subcommand()>
will run the default subcommand instead.

When there are no subcommands, e.g.:

 my $cmd = Perinci::CmdLine->new(url => '/MyApp/func');

C<_subcommand> will simply contain C<< {url=>'/MyApp/func'} >>.

C<run_subcommand()> will call the function specified in the C<url> in the
C<_subcommand> using C<Perinci::Access>. (Actually, C<run_help()> or
C<run_completion()> can be called instead, depending on which action to run.)


=head1 LOGGING

Logging is done with L<Log::Any> (for producing) and L<Log::Any::App> (for
displaying to outputs). Loading Log::Any::App will add to startup overhead time,
so this module tries to be smart when determining whether or not to do logging
output (i.e. whether or not to load Log::Any::App). Here are the order of rules
being used:

=over

=item * If running shell completion (C<COMP_LINE> is defined), output is off

Normally, shell completion does not need to show log output.

=item * If LOG environment is defined, use that

You can make a command-line program start a bit faster if you use LOG=0.

=item * If subcommand's log_any_app setting is defined, use that

This allows you, e.g. to turn off logging by default for subcommands that need
faster startup time. You can still turn on logging for those subcommands by
LOG=1.

=item * If action metadata's default_log setting is defined, use that

For example, actions like C<help>, C<list>, and C<version> has C<default_log>
set to 0, for faster startup time. You can still turn on logging for those
actions by LOG=1.

=item * Use log_any_app attribute setting

=back


=head1 UTF8 OUTPUT

By default, C<< binmode(STDOUT, ":utf8") >> is issued if utf8 output is desired.
This is determined by, in order:

=over

=item * Use setting from environment UTF8, if defined.

This allows you to force-disable or force-enable utf8 output.

=item * Use setting from action metadata, if defined.

Some actions like L<help>, L<list>, and L<version> output translated text, so
they have their C<use_utf8> metadata set to 1.

=item * Use setting from subcommand, if defined.

=item * Use setting from C<use_utf8> attribute.

This attribute comes from L<SHARYANTO::Role::TermAttrs>, its default is
determined from L<UTF8> environment as well as terminal's capabilities.

=back


=head1 COLOR THEMES

By default colors are used, but if terminal is detected as not having color
support, they are turned off. You can also turn off colors by setting COLOR=0 or
using PERINCI_CMDLINE_COLOR_THEME=Default::no_color.


=head1 COMMAND-LINE OPTION/ARGUMENT PARSING

This section describes how Perinci::CmdLine parses command-line
options/arguments into function arguments. Command-line option parsing is
implemented by L<Perinci::Sub::GetArgs::Argv>.

For boolean function arguments, use C<--arg> to set C<arg> to true (1), and
C<--noarg> to set C<arg> to false (0). A flag argument (C<< [bool => {is=>1}]
>>) only recognizes C<--arg> and not C<--noarg>. For single letter arguments,
only C<-X> is recognized, not C<--X> nor C<--noX>.

For string and number function arguments, use C<--arg VALUE> or C<--arg=VALUE>
(or C<-X VALUE> for single letter arguments) to set argument value. Other scalar
arguments use the same way, except that some parsing will be done (e.g. for date
type, --arg 1343920342 or --arg '2012-07-31' can be used to set a date value,
which will be a DateTime object.) (Note that date parsing will be done by
L<Data::Sah> and currently not implemented yet.)

For arguments with type array of scalar, a series of C<--arg VALUE> is accepted,
a la L<Getopt::Long>:

 --tags tag1 --tags tag2 ; # will result in tags => ['tag1', 'tag2']

For other non-scalar arguments, also use C<--arg VALUE> or C<--arg=VALUE>, but
VALUE will be attempted to be parsed using JSON, and then YAML. This is
convenient for common cases:

 --aoa  '[[1],[2],[3]]'  # parsed as JSON
 --hash '{a: 1, b: 2}'   # parsed as YAML

For explicit JSON parsing, all arguments can also be set via --ARG-json. This
can be used to input undefined value in scalars, or setting array value without
using repetitive C<--arg VALUE>:

 --str-json 'null'    # set undef value
 --ary-json '[1,2,3]' # set array value without doing --ary 1 --ary 2 --ary 3
 --ary-json '[]'      # set empty array value

Likewise for explicit YAML parsing:

 --str-yaml '~'       # set undef value
 --ary-yaml '[a, b]'  # set array value without doing --ary a --ary b
 --ary-yaml '[]'      # set empty array value


=head1 BASH COMPLETION

To do bash completion, first create your script, e.g. C<myscript>, that uses
Perinci::CmdLine:

 #!/usr/bin/perl
 use Perinci::CmdLine;
 Perinci::CmdLine->new(...)->run;

then execute this in C<bash> (or put it in bash startup files like
C</etc/bash.bashrc> or C<~/.bashrc> for future sessions):

 % complete -C myscript myscript; # myscript must be in PATH


=head1 PROGRESS INDICATOR

For functions that express that they do progress updating (by setting their
C<progress> feature to true), Perinci::CmdLine will setup an output, currently
either L<Progress::Any::Output::TermProgressBar> if program runs interactively,
or L<Progress::Any::Output::LogAny> if program doesn't run interactively.


=head1 ATTRIBUTES

=head2 program_name => STR (default from $0)

=head2 use_utf8 => BOOL

From L<SHARYANTO::Role::TermAttrs> (please see its docs for more details). There
are several other attributes added by the role.

=head2 url => STR

Required if you only want to run one function. URL should point to a function
entity.

Alternatively you can provide multiple functions from which the user can select
using the first argument (see B<subcommands>).

=head2 summary => STR

If unset, will be retrieved from function metadata when needed.

=head2 action_metadata => HASH

Contains a list of known actions and their metadata. Keys should be action
names, values should be metadata. Metadata is a hash containing these keys:

=over

=item * default_log => BOOL (optional)

Whether to enable logging by default (Log::Any::App) when C<LOG> environment
variable is not set. To speed up program startup, logging is by default turned
off for simple actions like C<help>, C<list>, C<version>.

=item * use_utf8 => BOOL (optional)

Whether to issue C<< binmode(STDOUT, ":utf8") >>. See L</"UTF8 OUTPUT"> for more
details.

=back

=head2 subcommands => {NAME => {ARGUMENT=>...}, ...} | CODEREF

Should be a hash of subcommand specifications or a coderef.

Each subcommand specification is also a hash(ref) and should contain these keys:

=over

=item * C<url> (str, required)

Location of function (accessed via Riap).

=item * C<summary> (str, optional)

Will be retrieved from function metadata at C<url> if unset

=item * C<description> (str, optional)

Shown in verbose help message, if description from function metadata is unset.

=item * C<tags> (array of str, optional)

For grouping or categorizing subcommands, e.g. when displaying list of
subcommands.

=item * C<log_any_app> (bool, optional)

Whether to load Log::Any::App, default is true. For subcommands that need fast
startup you can try turning this off for said subcommands. See L</"LOGGING"> for
more details.

=item * C<use_utf8> (bool, optional)

Whether to issue L<< binmode(STDOUT, ":utf8") >>. See L</"LOGGING"> for more
details.

=item * C<undo> (bool, optional)

Can be set to 0 to disable transaction for this subcommand; this is only
relevant when C<undo> attribute is set to true.

=item * C<show_in_help> (bool, optional, default 1)

If you have lots of subcommands, and want to show only some of them in --help
message, set this to 0 for subcommands that you do not want to show.

=item * C<pass_cmdline_object> (bool, optional, default 0)

To override C<pass_cmdline_object> attribute on a per-subcommand basis.

=item * C<args> (hash, optional)

If specified, will send the arguments (as well as arguments specified via the
command-line). This can be useful for a function that serves more than one
subcommand, e.g.:

 subcommands => {
     sub1 => {
         summary => 'Subcommand one',
         url     => '/some/func',
         args    => {flag=>'one'},
     },
     sub2 => {
         summary => 'Subcommand two',
         url     => '/some/func',
         args    => {flag=>'two'},
     },
 }

In the example above, both subcommand C<sub1> and C<sub2> point to function at
C</some/func>. But the function can differentiate between the two via the
C<flag> argument being sent.

 % cmdprog sub1 --foo 1 --bar 2
 % cmdprog sub2 --foo 2

In the first invocation, function will receive arguments C<< {foo=>1, bar=>2,
flag=>'one'} >> and for the second: C<< {foo=>2, flag=>'two'} >>.

=back

Subcommands can also be a coderef, for dynamic list of subcommands. The coderef
will be called as a method with hash arguments. It can be called in two cases.
First, if called without argument C<name> (usually when doing --list) it must
return a hashref of subcommand specifications. If called with argument C<name>
it must return subcommand specification for subcommand with the requested name
only.

=head2 default_subcommand => NAME

If set, subcommand will always be set to this instead of from the first
argument. To use other subcommands, you will have to use --cmd option.

=head2 common_opts => HASH

A hash of common options, which are command-line options that are not associated
with any subcommand. Each option is itself a specification hash containing these
keys:

=over

=item * category (str)

Optional, for grouping options in help/usage message, defaults to C<Common
options>.

=item * getopt (str)

Required, for Getopt::Long specification.

=item * handler (code)

Required, for Getopt::Long specification.

=item * usage (str)

Optional, displayed in usage line in help/usage text.

=item * summary (str)

Optional, displayed in description of the option in help/usage text.

=item * show_in_usage (bool or code, default: 1)

A flag, can be set to 0 if we want to skip showing this option in usage in
--help, to save some space. The default is to show all, except --subcommand when
we are executing a subcommand (obviously).

=item * show_in_options (bool or code, default: 1)

A flag, can be set to 0 if we want to skip showing this option in options in
--help. The default is to 0 for --help and --version in compact help. Or
--subcommands, if we are executing a subcommand (obviously).

=item * order (int)

Optional, for ordering. Lower number means higher precedence, defaults to 1.

=back

A partial example from the default set by the framework:

 {
     help => {
         category        => 'Common options',
         getopt          => 'help|h|?',
         usage           => '--help (or -h, -?)',
         handler         => sub { ... },
         order           => 0,
         show_in_options => sub { $ENV{VERBOSE} },
     },
     format => {
         category    => 'Common options',
         getopt      => 'format=s',
         summary     => 'Choose output format, e.g. json, text',
         handler     => sub { ... },
     },
     undo => {
         category => 'Undo options',
         getopt   => 'undo',
         ...
     },
     ...
 }

The default contains: help (getopt C<help|h|?>), version (getopt C<version|v>),
action (getopt C<action>), format (getopt C<format=s>), format_options (getopt
C<format-options=s>). If there are more than one subcommands, this will also be
added: list (getopt C<list|l>). If dry-run is supported by function, there will
also be: dry_run (getopt C<dry-run>). If undo is turned on, there will also be:
undo (getopt C<undo>), redo (getopt C<redo>), history (getopt C<history>),
clear_history (getopt C<clear-history>).

Sometimes you do not want some options, e.g. to remove C<format> and
C<format_options>:

 delete $cmd->common_opts->{format};
 delete $cmd->common_opts->{format_options};
 $cmd->run;

Sometimes you want to rename some command-line options, e.g. to change version
to use capital C<-V> instead of C<-v>:

 $cmd->common_opts->{version}{getopt} = 'version|V';

Sometimes you want to add subcommands as common options instead. For example:

 $cmd->common_opts->{halt} = {
     category    => 'Server options',
     getopt      => 'halt',
     summary     => 'Halt the server',
     handler     => sub {
         $cmd->{_selected_subcommand} = 'shutdown';
     },
 };

This will make:

 % cmd --halt

equivalent to executing the 'shutdown' subcommand:

 % cmd shutdown

=head2 exit => BOOL (default 1)

If set to 0, instead of exiting with exit(), run() will return the exit code
instead.

=head2 log_any_app => BOOL (default: 1)

Whether to load L<Log::Any::App> (enable logging output) by default. See
L</"LOGGING"> for more details.

=head2 custom_completer => CODEREF

Will be passed to L<Perinci::Sub::Complete>'s C<shell_complete_arg()>. See its
documentation for more details.

=head2 custom_arg_completer => CODEREF | {ARGNAME=>CODEREF, ...}

Will be passed to L<Perinci::Sub::Complete>'s C<shell_complete_arg()>. See its
documentation for more details.

=head2 pass_cmdline_object => BOOL (optional, default 0)

Whether to pass special argument C<-cmdline> containing the Perinci::CmdLine
object to function. This can be overriden using the C<pass_cmdline_object> on a
per-subcommand basis.

Passing the cmdline object can be useful, e.g. to call run_help(), etc.

=head2 pa_args => HASH

Arguments to pass to L<Perinci::Access>. This is useful for passing e.g. HTTP
basic authentication to Riap client (L<Perinci::Access::HTTP::Client>):

 pa_args => {handler_args => {user=>$USER, password=>$PASS}}

=head2 undo => BOOL (optional, default 0)

Whether to enable undo/redo functionality. Some things to note if you intend to
use undo:

=over 4

=item * These common command-line options will be recognized

C<--undo>, C<--redo>, C<--history>, C<--clear-history>.

=item * Transactions will be used

C<< use_tx=>1 >> will be passed to L<Perinci::Access>, which will cause it to
initialize the transaction manager. Riap requests begin_tx and commit_tx will
enclose the call request to function.

=item * Called function will need to support transaction and undo

Function which does not meet qualifications will refuse to be called.

Exception is when subcommand is specified with C<< undo=>0 >>, where transaction
will not be used for that subcommand. For an example of disabling transaction
for some subcommands, see C<bin/u-trash> in the distribution.

=back

=head2 undo_dir => STR (optional, default ~/.<program_name>/.undo)

Where to put undo data. This is actually the transaction manager's data dir.


=head1 METHODS

=head2 new(%opts) => OBJ

Create an instance.

=head2 run() -> INT

The main routine. Its job is to parse command-line options in @ARGV and
determine which action method (e.g. run_subcommand(), run_help(), etc) to run.
Action method should return an integer containing exit code. If action method
returns undef, the next action candidate method will be tried.

After that, exit() will be called with the exit code from the action method (or,
if C<exit> attribute is set to false, routine will return with exit code
instead).


=head1 METADATA PROPERTY ATTRIBUTE

This module observes the following Rinci metadata property attributes:

=head2 x.perinci.cmdline.default_format => STR

Set default output format (if user does not specify via --format command-line
option).


=head1 RESULT METADATA

This module interprets the following result metadata keys:

=head2 is_stream => BOOL

XXX should perhaps be defined as standard in L<Rinci::function>.

If set to 1, signify that result is a stream. Result must be a glob, or an
object that responds to getline() and eof() (like a Perl L<IO::Handle> object),
or an array/tied array. Format must currently be C<text> (streaming YAML might
be supported in the future). Items of result will be displayed to output as soon
as it is retrieved, and unlike non-streams, it can be infinite.

An example function:

 $SPEC{cat_file} = { ... };
 sub cat_file {
     my %args = @_;
     open my($fh), "<", $args{path} or return [500, "Can't open file: $!"];
     [200, "OK", $fh, {is_stream=>1}];
 }

another example:

 use Tie::Simple;
 $SPEC{uc_file} = { ... };
 sub uc_file {
     my %args = @_;
     open my($fh), "<", $args{path} or return [500, "Can't open file: $!"];
     my @ary;
     tie @ary, "Tie::Simple", undef,
         SHIFT     => sub { eof($fh) ? undef : uc(~~<$fh> // "") },
         FETCHSIZE => sub { eof($fh) ? 0 : 1 };
     [200, "OK", \@ary, {is_stream=>1}];
 }

See also L<Data::Unixish> and L<App::dux> which deals with streams.

=head2 cmdline.display_result => BOOL

If you don't want to display function output (for example, function output is a
detailed data structure which might not be important for end users), you can set
C<cmdline.display_result> result metadata to false. Example:

 $SPEC{foo} = { ... };
 sub foo {
     ...
     [200, "OK", $data, {"cmdline.display_result"=>0}];
 }

=head2 cmdline.page_result => BOOL

If you want to filter the result through pager (currently defaults to
C<$ENV{PAGER}> or C<less -FRSX>), you can set C<cmdline.page_result> in result
metadata to true.

For example:

 $SPEC{doc} = { ... };
 sub doc {
     ...
     [200, "OK", $doc, {"cmdline.page_result"=>1}];
 }

=head2 cmdline.pager => STR

Instruct Perinci::CmdLine to use specified pager instead of C<$ENV{PAGER}> or
the default C<less> or C<more>.

=head2 cmdline.exit_code => INT

Instruct Perinci::CmdLine to use this exit code, instead of using (function
status - 300).


=head1 ENVIRONMENT

=over

=item * PERINCI_CMDLINE_PROGRAM_NAME => STR

Can be used to set CLI program name.

=item * PERINCI_CMDLINE_COLOR_THEME => STR

Can be used to set C<color_theme>.

=item * PROGRESS => BOOL

Explicitly turn the progress bar on/off.

=item * PAGER => STR

Like in other programs, can be set to select the pager program (when
C<cmdline.page_result> result metadata is active). Can also be set to C<''> or
C<0> to explicitly disable paging even though C<cmd.page_result> result metadata
is active.

=item * COLOR => INT

Please see L<SHARYANTO::Role::TermAttrs>.

=item * UTF8 => BOOL

Please see L<SHARYANTO::Role::TermAttrs>.

=back


=head1 FAQ

=head2 How do I debug my program?

You can set environment DEBUG=1 or TRACE=1. See L<Log::Any::App> for more
details.

=head2 How does Perinci::CmdLine compare with other CLI-app frameworks?

The main difference is that Perinci::CmdLine accesses your code through L<Riap>
protocol, not directly. This means that aside from local Perl code,
Perinci::CmdLine can also provide CLI for code in remote hosts/languages. For a
very rough demo, download and run this PHP Riap::TCP server
https://github.com/sharyanto/php-Phinci/blob/master/demo/phi-tcpserve-terbilang.php
on your system. After that, try running:

 % peri-run riap+tcp://localhost:9090/terbilang --help
 % peri-run riap+tcp://localhost:9090/terbilang 1234

Everything from help message, calling, argument checking, tab completion works
for remote code as well as local Perl code.

=head2 How to add support for new output format (e.g. XML, HTML)?

See L<Perinci::Result::Format>.

=head2 My function has argument named 'format', but it is blocked by common option '--format'!

To add/remove/rename common options, see the documentation on C<common_opts>
attribute. In this case, you want:

 delete $cmd->common_opts->{format};
 #delete $cmd->common_opts->{format_options}; # you might also want this

or perhaps rename it:

 $cmd->common_opts->{output_format} = $cmd->common_opts->{format};
 delete $cmd->common_opts->{format};

=head2 How to accept input from STDIN (or files)?

If you specify 'cmdline_src' to 'stdin' to a 'str' argument, the argument's
value will be retrieved from standard input if not specified. Example:

 use Perinci::CmdLine;
 $SPEC{cmd} = {
     v => 1.1,
     args => {
         arg => {
             schema => 'str*',
             cmdline_src => 'stdin',
         },
     },
 };
 sub cmd {
     my %args = @_;
     [200, "OK", "arg is '$args{arg}'"];
 }
 Perinci::CmdLine->new(url=>'/main/cmd')->run;

When run from command line:

 % cat file.txt
 This is content of file.txt
 % cat file.txt | cmd
 arg is 'This is content of file.txt'

If your function argument is an array, array of lines will be provided to your
function. A mechanism to be will be provided in the future (currently not yet
specified in L<Rinci::function> specification).

=head2 But I don't want the whole file content slurped into string/array, I want streaming!

If your function argument is of type C<stream> or C<filehandle>, an I/O handle
will be provided to your function instead. But this part is not implemented yet.

Currently, see L<App::dux> for an example on how to accomplish this on function
argument of type C<array>. Basically in App::dux, you feed an array tied with
L<Tie::Diamond> as a function argument. Thus you can get lines from file/STDIN
iteratively with each().

=head2 My function has some cmdline_aliases or cmdline_src defined but I want to change it!

For example, your C<f1> function metadata might look like this:

 package Package::F1;
 our %SPEC;
 $SPEC{f1} = {
     v => 1.1,
     args => {
         foo => {
             cmdline_aliases => { f=> {} },
         },
         bar => { ... },
         fee => { ... },
     },
 };
 sub f1 { ... }
 1;

And your command-line script C<f1>:

 #!perl
 use Perinci::CmdLine;
 Perinci::CmdLine->new(url => '/Package/F1/f1')->run;

Now you want to create a command-line script interface for this function, but
with C<-f> as an alias for C<--fee> instead of C<--foo>. This is best done by
modifying the metadata and creating a wrapper function to do this, e.g. your
command-line script C<f1> becomes:

 package main;
 use Perinci::CmdLine;
 use Package::F1;
 use Data::Clone;
 our %SPEC;
 $SPEC{f1} = clone $Package::F1::SPEC{f1};
 delete $SPEC{f1}{args}{foo}{cmdline_aliases};
 $SPEC{f1}{args}{fee}{cmdline_aliases} = {f=>{}};
 *f1 = \&Package::F1::f1;
 Perinci::CmdLine->new(url => '/main/f1')->run;

This also demonstrates the convenience of having the metadata as a data
structure: you can manipulate it however you want.

=head2 How to do custom completion for my argument?

By default, L<Perinci::Sub::Complete>'s C<complete_arg_val()> can employ some
heuristics to complete argument values, e.g. from the C<in> clause or C<max> and
C<min>:

 $SPEC{set_ticket_status} = {
     v => 1.1,
     args => {
         ticket_id => { ... },
         status => {
             schema => ['str*', in => [qw/new open stalled resolved rejected/],
         },
     },
 }

But if you want to supply custom completion, the L<Rinci::function>
specification allows specifying a C<completion> property for your argument, for
example:

 use Perinci::Sub::Complete qw(complete_array);
 $SPEC{del_user} = {
     v => 1.1,
     args => {
         username => {
             schema => 'str*',
             req => 1,
             pos => 0,
             completion => sub {
                 my %args = @_;

                 # get list of users from database or whatever
                 my @users = ...;
                 complete_array(array=>\@users, word=>$args{word});
             },
         },
         ...
     },
 };

You can use completion your command-line program:

 % del-user --username <tab>
 % del-user <tab> ; # since the 'username' argument has pos=0

=head2 My custom completion does not work, how do I debug it?

Completion works by the shell invoking our (the same) program with C<COMP_LINE>
and C<COMP_POINT> environment variables. You can do something like this to see
debugging information:

 % COMP_LINE='myprog --arg x' COMP_POINT=13 PERL5OPT=-MLog::Any::App TRACE=1 myprog --arg x

=head2 My application is OO?

This framework is currently non-OO and function-centric. There are already
several OO-based command-line frameworks on CPAN.


=head1 TODOS

C<cmdline_src> argument specification has not been fully implemented: Providing
I/O handle for argument of type C<stream>/C<filehandle>.


=head1 SEE ALSO

L<Perinci>, L<Rinci>, L<Riap>.

Other CPAN modules to write command-line applications: L<App::Cmd>, L<App::Rad>,
L<MooseX::Getopt>.

=cut

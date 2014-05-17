#!perl

use 5.010;
use strict;
use warnings;
use Log::Any '$log';
use Test::More 0.96;

use Capture::Tiny qw(capture);
use File::Slurp::Tiny qw(write_file);
use File::Temp qw(tempfile);
use Perinci::CmdLine;

# XXX test formats

package Foo;
our $VERSION = "0.123";
our $DATE = "1999-01-01";
our %SPEC;

$SPEC{':package'} = {v=>1.1};

$SPEC{noop} = {
    v => 1.1,
    summary => 'Always return noop',
};
sub noop {
    [304, "Nothing done"];
}

$SPEC{ok} = {
    v => 1.1,
    summary => 'Always return ok',
    args => {
        arg1 => {schema=>['str*' => {in=>[qw/a b c d/]}], pos=>0, req=>1},
        arg2 => {schema=>['str*'], pos=>1, req=>1},
        arg3 => {schema=>'str'},
    },
};
sub ok {
    my %args = @_;
    [200, "OK",
     {
         "First argument"=>$args{arg1},
         "Second argument"=>$args{arg2},
         "Third argument"=>$args{arg3},
     }];
}

$SPEC{want_odd} = {
    v => 1.1,
    summary => 'Return error if given an even number',
    args => {
        num => { schema => 'int*', pos=>0 },
    },
};
sub want_odd {
    my %args = @_;
    if ($args{num} % 2) {
        [200, "OK"];
    } else {
        [400, "You know I hate even numbers, right?"];
    }
}

$SPEC{f1} = {
    v => 1.1,
    summary => 'This function has arguments with names like "help", "subcommands"',
    args => {
        help => {schema=>'bool'},
        subcommands => {schema=>'bool'},
    },
};
sub f1 {
    my %args = @_;
    [200, "OK", $args{help} ? "tolong" : $args{subcommands} ? "daftar" : "?"];
}

$SPEC{f2} = {
    v => 1.1,
    summary => 'This function has required positional argument',
    args => {
        a1 => {schema=>'str*', req=>1, pos=>0},
    },
};
sub f2 {
    my %args = @_;
    [200, "OK", $args{a1}];
}

$SPEC{f2r} = {
    v => 1.1,
    summary => 'This function has required positional argument',
    args => {
        a1 => {schema=>'str*', req=>1, pos=>0},
    },
};
sub f2r {
    my %args = @_;
    [200, "OK", scalar(reverse $args{a1})];
}

$SPEC{sp1} = {
    v => 1.1,
    summary => 'This function supports dry run',
    args => {},
    features => {dry_run=>1},
};
sub sp1 {
    my %args = @_;
    [200, "OK", "dry_run=".($args{-dry_run} ? 1:0)];
}

$SPEC{cmdline_src_unknown} = {
    v => 1.1,
    summary => 'This function has arg with unknown cmdline_src value',
    args => {
        a1 => {schema=>'str*', cmdline_src=>'foo'},
    },
};
sub cmdline_src_unknown {
    my %args = @_;
    [200, "OK", "a1=$args{a1}"];
}

$SPEC{cmdline_src_invalid_arg_type} = {
    v => 1.1,
    summary => 'This function has non-str/non-array arg with cmdline_src',
    args => {
        a1 => {schema=>'int*', cmdline_src=>'stdin'},
    },
};
sub cmdline_src_invalid_arg_type {
    my %args = @_;
    [200, "OK", "a1=$args{a1}"];
}

$SPEC{cmdline_src_stdin_str} = {
    v => 1.1,
    summary => 'This function has arg with cmdline_src=stdin',
    args => {
        a1 => {schema=>'str*', cmdline_src=>'stdin'},
    },
};
sub cmdline_src_stdin_str {
    my %args = @_;
    [200, "OK", "a1=$args{a1}"];
}

$SPEC{cmdline_src_stdin_array} = {
    v => 1.1,
    summary => 'This function has arg with cmdline_src=stdin',
    args => {
        a1 => {schema=>'array*', cmdline_src=>'stdin'},
    },
};
sub cmdline_src_stdin_array {
    my %args = @_;
    [200, "OK", "a1=[".join(",",@{ $args{a1} })."]"];
}

$SPEC{cmdline_src_file} = {
    v => 1.1,
    summary => 'This function has args with cmdline_src _file',
    args => {
        a1 => {schema=>'str*', req=>1, cmdline_src=>'file'},
        a2 => {schema=>'array*', cmdline_src=>'file'},
    },
};
sub cmdline_src_file {
    my %args = @_;
    [200, "OK", "a1=$args{a1}\na2=[".join(",", @{ $args{a2} // [] })."]"];
}

$SPEC{cmdline_src_stdin_or_files_str} = {
    v => 1.1,
    summary => 'This function has str arg with cmdline_src=stdin_or_files',
    args => {
        a1 => {schema=>'str*', cmdline_src=>'stdin_or_files'},
    },
};
sub cmdline_src_stdin_or_files_str {
    my %args = @_;
    [200, "OK", "a1=$args{a1}"];
}

$SPEC{cmdline_src_stdin_or_files_array} = {
    v => 1.1,
    summary => 'This function has array arg with cmdline_src=stdin_or_files',
    args => {
        a1 => {schema=>'array*', cmdline_src=>'stdin_or_files'},
    },
};
sub cmdline_src_stdin_or_files_array {
    my %args = @_;
    [200, "OK", "a1=[".join(",",@{ $args{a1} })."]"];
}

$SPEC{cmdline_src_multi_stdin} = {
    v => 1.1,
    summary => 'This function has multiple args with cmdline_src stdin/stdin_or_files',
    args => {
        a1 => {schema=>'str*', cmdline_src=>'stdin_or_files'},
        a2 => {schema=>'str*', cmdline_src=>'stdin'},
    },
};
sub cmdline_src_multi_stdin {
    my %args = @_;
    [200, "OK", "a1=$args{a1}\na2=$args{a2}"];
}

$SPEC{dry_run} = {
    v => 1.1,
    features => {dry_run=>1},
};
sub dry_run {
    my %args = @_;
    [200, "OK", $args{-dry_run} ? 1:2];
}

$SPEC{tx} = {
    v => 1.1,
    features => {tx=>{v=>2}, idempotent=>1},
};
sub tx {
    my %args = @_;
    [200, "OK", $args{-tx_action} eq 'check_state' ? 1:2];
}

package main;

subtest 'completion' => sub {
    test_complete(
        name        => 'arg name (single sub)',
        argv        => [],
        args        => {url=>'/Foo/ok'},
        comp_line   => 'CMD -',
        comp_point0 => '     ^',
        result      => [qw(--action
                           --arg1 --arg2 --arg3 --debug
                           --format --format-options
                           --help --log-level --quiet
                           --trace --verbose --version
                           -\? -h -v

                      )],
    );
    test_complete(
        name        => 'arg name (with subcommands)',
        argv        => [],
        args      => {subcommands=>{
            ok=>{url=>'/Foo/ok'},
            wo=>{url=>'/Foo/want_odd'}}},
        comp_line   => 'CMD -',
        comp_point0 => '     ^',
        result      => [qw(
                           --action
                           --debug --format --format-options
                           --help --log-level --quiet --subcommands
                           --trace --verbose --version
                           -\? -h -v
                      )],
    );
    test_complete(
        name        => 'arg name (with subcommands + default_subcommand)',
        argv        => [],
        args      => {subcommands=>{
            ok=>{url=>'/Foo/ok'},
            wo=>{url=>'/Foo/want_odd'}},
                  default_subcommand=>'wo'},
        comp_line   => 'CMD -',
        comp_point0 => '     ^',
        result      => [qw(
                           --action
                           --cmd
                           --debug --format --format-options
                           --help --log-level --quiet --subcommands
                           --trace --verbose --version
                           -\? -h -v
                      )],
    );

    test_complete(
        name        => 'arg value from arg spec "in" (single sub)',
        argv        => [],
        args        => {url=>'/Foo/ok'},
        comp_line   => 'CMD ',
        comp_point0 => '    ^',
        result      => [qw(a b c d)],
    );
    test_complete(
        name        => 'arg value from "custom_arg_completer" (single sub)',
        argv        => [],
        args        => {url=>'/Foo/ok',
                        custom_arg_completer=>sub {[qw(e f g h)]}},
        comp_line   => 'CMD arg1 ',
        comp_point0 => '         ^',
        result      => [qw(e f g h)],
    );
    test_complete(
        name        => 'arg value from "custom_arg_completer" (single sub) (2)',
        argv        => [],
        args        => {url=>'/Foo/ok',
                        custom_arg_completer=>{arg2=>sub{[qw(e f g h)]}}},
        comp_line   => 'CMD arg1 ',
        comp_point0 => '         ^',
        result      => [qw(e f g h)],
    );
    test_complete(
        name        => '--dry-run',
        argv        => [],
        args        => {url=>'/Foo/sp1'},
        comp_line   => 'CMD --dr',
        comp_point0 => '        ^',
        result      => [qw(--dry-run)],
    );
};

test_run(name      => 'single sub',
         args      => {url=>'/Foo/ok'},
         argv      => [qw/--arg1 a --arg2 2/],
         exit_code => 0,
         output_re => qr/First argument/,
     );

test_run(name      => 'missing arg = error',
         args      => {url=>'/Foo/ok'},
         argv      => [qw//],
         dies      => 1,
     );
test_run(name      => 'unknown arg = error',
         args      => {url=>'/Foo/ok'},
         argv      => [qw/--arg4/],
         dies      => 1,
     );
test_run(name      => 'exit code from sub res',
         args      => {url=>'/Foo/want_odd'},
         argv      => [qw/4/],
         exit_code => 100,
         output_re => qr/hate/,
     );

test_run(name      => 'subcommands',
         args      => {subcommands=>{
             ok=>{url=>'/Foo/ok'},
             wo=>{url=>'/Foo/want_odd'}}},
         argv      => [qw/wo 3/],
         exit_code => 0,
     );

subtest 'subcommand specification' => sub {
    my %cmdspec = (
        subcommands=>{
            ok1=>{url=>'/Foo/ok', args=>{arg3=>'mandiri'}},
            ok2=>{url=>'/Foo/ok', args=>{arg3=>'fiesta'}},
        },
    );

    test_run(name      => 'args specification',
             args      => \%cmdspec,
             argv      => [qw/ok1 a virus/],
             exit_code => 0,
             output_re => qr/a.+virus.+mandiri/s,
     );
    test_run(name      => 'args specification',
             args      => \%cmdspec,
             argv      => [qw/ok2 a virus/],
             exit_code => 0,
             output_re => qr/a.+virus.+fiesta/s,
     );
};

test_run(name      => 'unknown subcommand = error',
         args      => {subcommands=>{
             ok=>{url=>'/Foo/ok'},
             wo=>{url=>'/Foo/want_odd'}}},
         argv      => [qw/foo/],
         dies      => 1,
     );

test_run(name      => 'default_subcommand (1)',
         args      => {subcommands=>{
             f2=>{url=>'/Foo/f2'},
             f2r=>{url=>'/Foo/f2r'}},
                       default_subcommand=>'f2'},
         argv      => [qw/mirror/],
         output_re => qr/mirror/,
         exit_code => 0,
     );
test_run(name      => 'default_subcommand (2, other subcommand via --cmd)',
         args      => {subcommands=>{
             f2=>{url=>'/Foo/f2'},
             f2r=>{url=>'/Foo/f2r'}},
                       default_subcommand=>'f2'},
         argv      => [qw/--cmd=f2r mirror/],
         output_re => qr/rorrim/,
         exit_code => 0,
     );

for (qw(--help -h -?)) {
    test_run(name      => "general help ($_)",
             args      => {url=>'/Foo/'},
             argv      => [$_],
             exit_code => 0,
             output_re => qr/Usage/m,
         );
}

{
    local $ENV{COLOR} = 0;
    test_run(name      => "common option (--version) before subcommand name",
             args      => {url=>'/Foo/', subcommands=>{
                 ok=>{url=>'/Foo/ok'},
                 want_odd=>{url=>'/Foo/want_odd'}}},
             argv      => [qw/--version want_odd --num 4/],
             exit_code => 0,
             output_re => qr/version 0\.123/m,
         );
}
test_run(name      => "common option (--help) after subcommand name",
         args      => {subcommands=>{
             ok=>{url=>'/Foo/ok'},
             want_odd=>{url=>'/Foo/want_odd'}}},
         argv      => [qw/want_odd --num 4 --help/],
         exit_code => 0,
         output_re => qr/Return error if given/,
     );
test_run(name      => "common option (--help) overrides function argument",
         args      => {subcommands=>{f1=>{url=>'/Foo/f1'}}},
         argv      => [qw/f1 --help/],
         exit_code => 0,
         output_re => qr/Usage/m,
     );
test_run(name      => "common option (--help) does not override ".
             "function argument when using --action=call",
         args      => {subcommands=>{f1=>{url=>'/Foo/f1'}}},
         argv      => [qw/f1 --help --action=call/],
         exit_code => 0,
         output_re => qr/^tolong/m,
     );
test_run(name      => "common option (--help) bypass required argument check",
         args      => {url=>'/Foo/f2'},
         argv      => [qw/--help/],
         exit_code => 0,
         output_re => qr/Usage/m,
     );

# disabled for now, fail under 'prove'? wtf?
#for (qw(--version -v)) {
#    test_run(name      => "version ($_)",
#             args      => {url=>'/Foo/', subcommands=>{
#                 ok=>{url=>'/Foo/ok'},
#                 want_odd=>{url=>'/Foo/want_odd'}}},
#             argv      => [$_],
#             exit_code => 0,
#             output_re => qr/version 0\.123 \(1999-01-01\)/,
#         );
#}

for (qw(--subcommands)) {
    test_run(name      => "subcommands ($_)",
             args      => {subcommands=>{
                 ok=>{url=>'/Foo/ok'},
                 want_odd=>{url=>'/Foo/want_odd'}}},
             argv      => [$_],
             exit_code => 0,
         );
}

# XXX test arg: custom general help
# XXX test arg: per-subcommand help
# XXX test arg: custom per-subcommand help

{
    local $ENV{DRY_RUN} = 0;
    test_run(name      => 'dry-run (0)',
         args      => {url=>'/Foo/sp1'},
         argv      => [],
         exit_code => 0,
         output_re => qr/dry_run=0/m,
     );
    test_run(name      => 'dry-run (1)',
         args      => {url=>'/Foo/sp1'},
         argv      => [qw/--dry-run/],
         exit_code => 0,
         output_re => qr/dry_run=1/m,
     );
    $ENV{DRY_RUN} = 1;
    test_run(name      => 'dry-run (via env)',
         args      => {url=>'/Foo/sp1'},
         argv      => [],
         exit_code => 0,
         output_re => qr/dry_run=1/m,
     );
}

test_run(name      => 'noop',
         args      => {url=>'/Foo/noop'},
         argv      => [],
         exit_code => 0,
     );

subtest 'cmdline_src' => sub {
    test_run(
        name => 'unknown value',
        args => {url=>'/Foo/cmdline_src_unknown'},
        argv => [],
        dies => 1,
    );
    test_run(
        name => 'arg type not str/array',
        args => {url=>'/Foo/cmdline_src_invalid_arg_type'},
        argv => [],
        dies => 1,
    );
    test_run(
        name => 'multiple stdin',
        args => {url=>'/Foo/cmdline_src_multi_stdin'},
        argv => [qw/a b/],
        dies => 1,
    );

    # file
    {
        my ($fh, $filename)   = tempfile();
        my ($fh2, $filename2) = tempfile();
        write_file($filename , 'foo');
        write_file($filename2, "bar\nbaz");
        test_run(
            name => 'file 1',
            args => {url=>'/Foo/cmdline_src_file'},
            argv => ['--a1', $filename],
            exit_code => 0,
            output_re => qr/a1=foo/,
        );
        test_run(
            name => 'file 2',
            args => {url=>'/Foo/cmdline_src_file'},
            argv => ['--a1', $filename, '--a2', $filename2],
            exit_code => 0,
            output_re => qr/a1=foo\na2=\[bar\n,baz\]/,
        );
        test_run(
            name => 'file not found',
            args => {url=>'/Foo/cmdline_src_file'},
            argv => ['--a1', $filename . "/x"],
            dies => 1,
        );
        test_run(
            name => 'file, missing required arg',
            args => {url=>'/Foo/cmdline_src_file'},
            argv => ['--a2', $filename],
            dies => 1,
        );
    }

    # stdin_or_files
    {
        my ($fh, $filename)   = tempfile();
        my ($fh2, $filename2) = tempfile();
        write_file($filename , 'foo');
        write_file($filename2, "bar\nbaz");
        test_run(
            name => 'stdin_or_files file',
            args => {url=>'/Foo/cmdline_src_stdin_or_files_str'},
            argv => [$filename],
            exit_code => 0,
            output_re => qr/a1=foo$/,
        );
        test_run(
            name => 'stdin_or_files file not found',
            args => {url=>'/Foo/cmdline_src_stdin_or_files_str'},
            argv => [$filename . "/x"],
            dies => 1,
        );

        # i don't know why these tests don't work, they should though. and if
        # tested via a cmdline script like
        # examples/cmdline_src-stdin_or_files-{str,array} they work fine.
        if (0) {
            open $fh, '<', $filename2;
            local *STDIN = $fh;
            local @ARGV;
            test_run(
                name => 'stdin_or_files stdin str',
                args => {url=>'/Foo/cmdline_src_stdin_or_files_str'},
                argv => [],
                exit_code => 0,
                output_re => qr/a1=bar\nbaz$/,
            );
        }
        if (0) {
            open $fh, '<', $filename2;
            local *STDIN = $fh;
            local @ARGV;
            test_run(
                name => 'stdin_or_files stdin str',
                args => {url=>'/Foo/cmdline_src_stdin_or_files_array'},
                argv => [],
                exit_code => 0,
                output_re => qr/a1=\[bar\n,baz\]/,
            );
        }
    }

    # stdin
    {
        my ($fh, $filename) = tempfile();
        write_file($filename, "bar\nbaz");

        open $fh, '<', $filename;
        local *STDIN = $fh;
        test_run(
            name => 'stdin str',
            args => {url=>'/Foo/cmdline_src_stdin_str'},
            argv => [],
            exit_code => 0,
            output_re => qr/a1=bar\nbaz/,
        );

        open $fh, '<', $filename;
        *STDIN = $fh;
        test_run(
            name => 'stdin array',
            args => {url=>'/Foo/cmdline_src_stdin_array'},
            argv => [],
            exit_code => 0,
            output_re => qr/a1=\[bar\n,baz\]/,
        );

        open $fh, '<', $filename;
        *STDIN = $fh;
        test_run(
            name => 'stdin + arg set to "-"',
            args => {url=>'/Foo/cmdline_src_stdin_str'},
            argv => [qw/--a1 -/],
            exit_code => 0,
            output_re => qr/a1=bar\nbaz/,
        );

        test_run(
            name => 'stdin + arg set to non "-"',
            args => {url=>'/Foo/cmdline_src_stdin_str'},
            argv => [qw/--a1 x/],
            dies => 1,
        );
    }

    done_testing;
};

test_run(name      => 'dry_run (using dry_run) (w/o)',
         args      => {url=>'/Foo/dry_run'},
         argv      => [],
         exit_code => 0,
         output_re => qr/2/,
     );
test_run(name      => 'dry_run (using dry_run) (w/)',
         args      => {url=>'/Foo/dry_run'},
         argv      => [qw/--dry-run/],
         exit_code => 0,
         output_re => qr/1/,
     );
test_run(name      => 'dry_run (using tx) (w/o)',
         args      => {url=>'/Foo/tx'},
         argv      => [],
         exit_code => 0,
         output_re => qr/2/,
     );
test_run(name      => 'dry_run (using tx) (w/)',
         args      => {url=>'/Foo/tx'},
         argv      => [qw/--dry-run/],
         exit_code => 0,
         output_re => qr/1/,
     );


DONE_TESTING:
done_testing();

sub test_run {
    my %args = @_;

    my $pc = Perinci::CmdLine->new(%{$args{args}}, exit=>0);

    local @ARGV = @{$args{argv}};
    my ($stdout, $stderr);
    my $exit_code;
    eval {
        if ($args{output_re}) {
            ($stdout, $stderr) = capture { $exit_code = $pc->run };
        } else {
            $exit_code = $pc->run;
        }
    };
    my $eval_err = $@;

    subtest $args{name} => sub {
        if ($args{dies}) {
            ok($eval_err || ref($eval_err), "dies");
        } else {
            ok(!$eval_err, "doesn't die") or diag("dies: $eval_err");
        }

        if ($args{exit_code}) {
            is($exit_code, $args{exit_code}, "exit code");
        }

        if ($args{output_re}) {
            like($stdout // "", $args{output_re}, "output_re")
                or diag("output is <" . ($stdout // "") . ">");
        }

        if ($args{posttest}) {
            $args{posttest}->(\@ARGV);
        }
    };
}

sub test_complete {
    my (%args) = @_;

    my $pc = Perinci::CmdLine->new(%{$args{args}}, exit=>0);

    local @ARGV = @{$args{argv}};
    local $ENV{COMP_LINE}  = $args{comp_line};
    local $ENV{COMP_POINT} = index($args{comp_point0}, "^");

    my ($stdout, $stderr);
    my $exit_code;
    ($stdout, $stderr) = capture {
        $exit_code = $pc->run;
    };

    subtest "completion: $args{name}" => sub {
        is($exit_code, 0, "exit code = 0");
        is($stdout // "", join("", map {"$_\n"} @{$args{result}}), "result");
    };
}

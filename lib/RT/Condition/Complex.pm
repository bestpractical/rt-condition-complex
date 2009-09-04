package RT::Condition::Complex;

use 5.008003;
use strict;
use warnings;

our $VERSION = '0.01';

use base 'RT::Condition';

=head1 NAME

RT::Condition::Complex - build complex conditions out of other conditions

=head1 DESCRIPTION

=cut

use Parse::BooleanLogic;
my $parser = new Parse::BooleanLogic;

use Regexp::Common qw(delimited);
my $re_quoted = qr{$RE{delimited}{-delim=>qq{\'\"}}{-esc=>'\\'}};

my $re_exec_module = qr{[a-z][a-z0-9-]+}i;
my $re_field = qr{[a-z.]+}i;
my $re_value = qr{$re_quoted|[-+]?[0-9]+};
my $re_bin_op = qr{!?=|[><]=?|(?:not\s+)?(?:contains|starts\s+with|ends\s+with)}i;
my $re_un_op = qr{IS\s+(?:NOT\s+)?NULL|}i;

my %op_handler = (
    '='  => sub { return $_[1] =~ /\D/? $_[0] eq $_[1] : $_[0] == $_[1] },
    '!=' => sub { return $_[1] =~ /\D/? $_[0] ne $_[1] : $_[0] != $_[1] },
    '>'  => sub { return $_[1] =~ /\D/? $_[0] gt $_[1] : $_[0] > $_[1] },
    '>=' => sub { return $_[1] =~ /\D/? $_[0] ge $_[1] : $_[0] >= $_[1] },
    '<'  => sub { return $_[1] =~ /\D/? $_[0] lt $_[1] : $_[0] < $_[1] },
    '<=' => sub { return $_[1] =~ /\D/? $_[0] le $_[1] : $_[0] <= $_[1] },
    'contains'         => sub { return index(lc $_[0], lc $_[1]) >= 0 },
    'not contains'     => sub { return index(lc $_[0], lc $_[1]) < 0 },
    'starts with'      => sub { return rindex(lc $_[0], lc $_[1], 0) == 0 },
    'not starts with'  => sub { return rindex(lc $_[0], lc $_[1], 0) < 0 },
    'ends with'        => sub { return rindex(lc reverse($_[0]), lc reverse($_[1]), 0) == 0 },
    'not ends with'    => sub { return rindex(lc reverse($_[0]), lc reverse($_[1]), 0) < 0 },
    'is null'          => sub { return !(defined $_[0] && length $_[0]) },
    'is not null'      => sub { return   defined $_[0] && length $_[0] },
);
my %field_handler = (
    ( map { my $m = $_; lc $m => sub { $_[1]->$m() } } qw(Type Field OldValue NewValue) ),
);

sub IsApplicable {
    my $self = shift;
    my ($tree, @errors) = $self->ParseCode;
    unless ( $tree ) {
        $RT::Logger->error(
            "Couldn't parse complex condition, errors:\n"
            . join("\n", map "\t* $_", @errors)
            . "\nCODE:\n"
            . $self->ScripObj->CustomIsApplicableCode
        );
        return 0;
    }
    return $self->Solve( $tree );
}

my $solver = sub {
    my $cond = shift;
    my $self = $_[0];
    if ( $cond->{'op'} ) {
        return $self->OpHandler($cond->{'op'})->(
            $self->GetField( $cond->{'lhs'}, @_ ),
            $self->GetValue( $cond->{'rhs'}, @_ )
        );
    }
    elsif ( $cond->{'module'} ) {
        my $module = 'RT::Condition::'. $cond->{'module'};
        eval "require $module;1" || die "Require of $module failed.\n$@\n";
        my $obj = $module->new (
            TransactionObj => $_[1],
            TicketObj      => $_[2],
            Argument       => $cond->{'argument'},
            CurrentUser    => $RT::SystemUser,
        );
        return $obj->IsApplicable;
    } else {
        die "Boo";
    }
};

sub Solve {
    my $self = shift;
    my $tree = shift;

    my $txn = $self->TransactionObj;
    my $ticket = $self->TicketObj;

    return $parser->solve( $tree, $solver, $self, $txn, $ticket );
}

sub ParseCode {
    my $self = shift;

    my $code = $self->ScripObj->CustomIsApplicableCode;

    my @errors = ();
    my $res = $parser->as_array(
        $code, 
        error_cb => sub { push @errors, $_[0]; },
        operand_cb => sub {
            my $op = shift;
            if ( $op =~ /^(!?)($re_exec_module)(?:{(.*)})?$/o ) {
                return { module => $2, negative => $1, argument => $3 };
            }
            elsif ( $op =~ /^($re_field)\s+($re_bin_op)\s+($re_value)$/o ) {
                return { op => $2, lhs => $1, rhs => $3 };
            }
            elsif ( $op =~ /^($re_field)\s+($re_un_op)$/o ) {
                return { op => $2, lhs => $1 };
            }
            else {
                push @errors, "'$op' is not a sub-condition Complex condition knows about";
                return undef;
            }
        },
    );
    return @errors? (undef, @errors) : ($res);
}

sub OpHandler {
    my $op = $_[1];
    $op =~ s/\s+/ /;
    return $op_handler{ lc $op };
}

sub GetField {
    my $self = shift;
    my $field = shift;
    return $field_handler{ lc $field }->(@_);
}

sub GetValue {
    my $self = shift;
    my $value = shift;
    return $value unless defined $value;
    return $value unless $value =~ /^$re_quoted$/o;
    return $parser->dq($value);
}

=head1 AUTHOR

Ruslan Zakirov E<lt>Ruslan.Zakirov@gmail.comE<gt>

=head1 LICENSE

Under the same terms as perl itself.

=cut

1;

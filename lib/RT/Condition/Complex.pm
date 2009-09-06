package RT::Condition::Complex;

use 5.008003;
use strict;
use warnings;

our $VERSION = '0.01';

use base 'RT::Condition';

=head1 NAME

RT::Condition::Complex - build complex conditions out of other conditions

=head1 DESCRIPTION

This extension adds new type of conditions to the RT. It's like User Defined
condition, shipped with RT, but you don't have to write any code, but instead
you use simple syntax to check properties of the ticket and transaction or
run other conditions you have.

There are several goals this extension tries to solve:

=over 4

=item code reusing - complex conditions still need coding, but often you
want to reuse them with additinal simple conditions or reuse some condition
many times with other. In RT you have to use User Defined condition or
module based condition to tie everything together and each time you copy
code around. With this condition you can check other module based conditins,
so you can re-use some of them many times in different combinations.

=item simplicity - make things more simple for poeple who don't know how
to program in perl, some complex things have to be programmed, but now
then can be reused.

=head1 HOW TO USE

You open the web interface in a browser, goto configuration, the global or
to specific queue and then scrips. Create a new scrip, on the creation
page you select 'Complex' condition and in the 'Custom is applicable code'
text box you write a pseudo code. For example:

    Type = 'Create' OR StatusChange{open}

Below you can read details on the syntax.

=head2 Basic syntax

Syntax is similar to TicketSQL and you can use AND/OR and parentheses "(" and
")" to group checks and build custom logic of your condition. As checks you
can use either L</Expressions> or L</Calls>.

=head2 Expressions

Expression is comparision of a field with a constant. For example "is type
of a transaction equal to "Create" can be writen as:

    Type = 'Create'

On the left you write L<field|/Fields> you want to check, then goes
L<comparision function|/Comparision functions> and a L<constant|/Constants>.

=head2 Comparision functions

At this moment the following comparision functions are supported:

=over 4

=item =, !=, >, >=, <, <= - basic comparisions, work for strings and numbers,
depends if constant is a string or number, string comparision is cases insensetive.

=item contains, not contains - the constant is substring of the field and negative variant.

=item starts with, not starts with - the constant is beginning of the field.

=item ends with, not ends with.

=back

=head2 Fields

At this moment not many fields are available, but it's easy to add more. Patches
are welcome. Here is the list:

=over 4

=item Type, Field, OldValue and NewValue - basic properties of the current transaction.

=back

=head2 Constants

Constant is a number or a quoted string. Strings can be quoted 
using ' or " characters. Character you're using for quoting should
be escaped with \ and \ should be escaped as well. For example:

    "Don't need to escape ' when string is quoted with double quotes."
    'But can escape \' with \\.'

=head2 Calls

It's possible to call another module based condition. For example you have
RT::Conditon::XXX that implements some complex condition then you can use
the following syntax to call 'XXX':

    XXX
    !XXX

If the condition is controlled by its argument then you can use:

    XXX{'quoted argument'}
    !XXX{'negation with argument'}

As you can see argument should be quoted, you can read about quoting
rules above in </Constants> section.

=cut

use Parse::BooleanLogic;
my $parser = new Parse::BooleanLogic;

use Regexp::Common qw(delimited);
my $re_quoted = qr{$RE{delimited}{-delim=>qq{\'\"}}{-esc=>'\\'}};

my $re_exec_module = qr{[a-z][a-z0-9-]+}i;
# module argument must be quoted as we don't know if it's quote to
# protect from AND/OR words or argument of the condition should be
# quoted
my $re_module_argument = qr{$re_quoted};
my $re_field = qr{[a-z.]+}i;
my $re_value = qr{$re_quoted|[-+]?[0-9]+};
my $re_bin_op = qr{!?=|[><]=?|(?:not\s+)?(?:contains|starts\s+with|ends\s+with)}i;
my $re_un_op = qr{IS\s+(?:NOT\s+)?NULL|}i;

my %op_handler = (
    '='  => sub { return $_[1] =~ /\D/? lc $_[0] eq lc $_[1] : $_[0] == $_[1] },
    '!=' => sub { return $_[1] =~ /\D/? lc $_[0] ne lc $_[1] : $_[0] != $_[1] },
    '>'  => sub { return $_[1] =~ /\D/? lc $_[0] gt lc $_[1] : $_[0] > $_[1] },
    '>=' => sub { return $_[1] =~ /\D/? lc $_[0] ge lc $_[1] : $_[0] >= $_[1] },
    '<'  => sub { return $_[1] =~ /\D/? lc $_[0] lt lc $_[1] : $_[0] < $_[1] },
    '<=' => sub { return $_[1] =~ /\D/? lc $_[0] le lc $_[1] : $_[0] <= $_[1] },
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
            if ( $op =~ /^(!?)($re_exec_module)(?:{$re_module_argument})?$/o ) {
                return { module => $2, negative => $1, argument => $parser->dq($3) };
            }
            elsif ( $op =~ /^($re_field)\s+($re_bin_op)\s+($re_value)$/o ) {
                return { op => $2, lhs => $1, rhs => $3 };
            }
            elsif ( $op =~ /^($re_field)\s+($re_un_op)$/o ) {
                return { op => $2, lhs => $1 };
            }
            else {
                push @errors, "'$op' is not a check 'Complex' condition knows about";
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

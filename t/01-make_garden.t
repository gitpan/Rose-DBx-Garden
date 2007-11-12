use Test::More tests => 16;

use File::Temp ( 'tempdir' );
use Rose::DBx::Garden;
use Rose::DBx::TestDB;
use Path::Class;
use Rose::HTML::Form;

my $debug = $ENV{PERL_DEBUG} || 0;

my $db = Rose::DBx::TestDB->new;

# create a schema that tests out all our column types

ok( $db->dbh->do(
        qq{
CREATE TABLE foo (
    id       integer primary key autoincrement,
    name     varchar(16),
    static   char(8),
    my_int   integer not null default 0,
    my_dec   float
    );
}
    ),
    "table foo created"
);

{

    package MyMetadata;
    use base qw( Rose::DB::Object::Metadata );

    # we override just this method since we don't actually need/want to
    # connect to the db, as the standard init_db() would. We need to
    # re-use our existing $db.
    sub init_db {
        my ($self) = shift;
        $self->{'db_id'} = $db->{'id'};
        return $db;
    }

    package MyRDBO;
    use base qw( Rose::DB::Object );

    sub meta_class {'MyMetadata'}
}

ok( my $garden = Rose::DBx::Garden->new(
        db              => $db,
        find_schemas    => 0,
        garden_prefix   => 'MyRDBO',
        force_install   => 1,
        column_to_label => sub {
            my ( $garden_obj, $col_name ) = @_;
            return join(
                ' ', map { ucfirst($_) }
                    split( m/_/, $col_name )
            );
        }
    ),
    "garden obj created"
);

my $dir = $debug ? '/tmp/rose_garden' : tempdir('rose_garden_XXXX', CLEANUP => 1);

ok( $garden->make_garden($dir), "make_garden" );

# are the files there?
ok( -s file( $dir, 'MyRDBO.pm' ), "base class exists" );
ok( -s file( $dir, 'MyRDBO', 'Foo.pm' ), "table class exists" );
ok( -s file( $dir, 'MyRDBO', 'Foo', 'Form.pm' ),    "form class exists" );
ok( -s file( $dir, 'MyRDBO', 'Foo', 'Manager.pm' ), "manager class exists" );

# do they compile?

for my $class (
    qw( MyRDBO MyRDBO::Form MyRDBO::Foo MyRDBO::Foo::Form MyRDBO::Foo::Manager )
    )
{

    # have to clean up the symbol table manually
    # since these classes were created at runtime and are
    # not in %INC.
    {
        no strict 'refs';
        local *symtable = $class . '::';
        for my $sym ( keys %symtable ) {
            delete $symtable{$sym};
        }
    }

    eval "use $class";
    ok( !$@, "require $class" );
    diag($@) and next if $@;

    if ( $class eq 'MyRDBO::Foo::Form' ) {
        ok( my $form = $class->new, "new $class" );
        is( $form->field('my_int')->label, 'My Int', "label callback works" );
        is( $form->field('my_int')->isa('Rose::HTML::Form::Field::Integer'),
            1, "my_int -> Integer field" );
        diag( $form->field('id') );

    SKIP: {
            if ( $Rose::HTML::Form::VERSION <= '0.550' )
            {
                skip( " -- change requested in default column mapping", 1 );
            }

            is( $form->field('id')->isa('Rose::HTML::Form::Field::Hidden'),
                1, "id field is hidden" );
        }

    }
}

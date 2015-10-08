#!/usr/bin/perl -w

use strict;
use Clone 'clone';

use lib("./lib");
use Nagios::Config;

use Data::Dumper;
sub mysort { my ($hash) = @_; [ sort keys %$hash ] };
# $Data::Dumper::Indent = 0; # не делать отступы/переводы строк
# $Data::Dumper::Pair = ':'; # знак вместо "=>" в конструкциях "key => val" И ОНА ЖЕ УБИРАЕТ КАВЫЧКИ вокруг цифровых ключей
# $Data::Dumper::Terse = 1; # убрать "$VAR = "
$Data::Dumper::Sortkeys = \&mysort; # для сортировки хэшей по ключам

# perl arrange2.pl OLD_VERSION
my $OLD_VERSION = ( defined($ARGV[0]) and $ARGV[0] eq 'OLD_VERSION' ) ? 1 : 0;

#### OPTIONS

    my $DEBUG = ( defined( $ARGV[0] ) and $ARGV[0] eq 'nodebug' ) ? 0 : 1;

    ###################################################################
    my $BASE_DIR    = qq[/Users/dalp/Dropbox/Projects/nagcfg/etc];
    ###################################################################

    my $CFG_IN      = qq[$BASE_DIR/objects];
    my $CFG_OUT     = qq[$BASE_DIR/prepared];

    mkdir $CFG_OUT if not -d $CFG_OUT; # ну мало ли

    my $DIR_TEMPLATES_OUT;
    for my $site ( 1, 2 )
    {
        $DIR_TEMPLATES_OUT->{$site} = qq[$CFG_OUT/local.config$site];
        # файлы будут дописываться в конец. Поэтому перед началом работы удаляем и создаем
        # (пустые) выходные каталоги каталоги и файлы, чтобы не получилось накладок
        system("rm -rf " . $DIR_TEMPLATES_OUT->{$site}) if length($CFG_OUT) > 7 and -d $CFG_OUT;
        mkdir $DIR_TEMPLATES_OUT->{$site} if not -d $DIR_TEMPLATES_OUT->{$site};
    }

    my $FILE_HOSTGROUPS_IN  = qq[$CFG_IN/hostgroups-sites.cfg];
    my $FILE_HOSTGROUPS_OUT = qq[$CFG_OUT/hostgroups-sites.cfg];

    # т.к. файл с группами будет пополняться с каждым обработанным конфигом,
    # то каждый раз мы должны открывать уже пополненный файл, а не входной.
    # копируем входной в выходной и в дальнейшем используем только выходной, и для чтения, и для записи
    system( "rm -f " . $FILE_HOSTGROUPS_OUT )               if -e $FILE_HOSTGROUPS_OUT;
    system( "cp $FILE_HOSTGROUPS_IN $FILE_HOSTGROUPS_OUT" ) if -e $FILE_HOSTGROUPS_IN;

    # заполняется внутри build_links_item_to_site(), для определения площадки по имени хоста, или группы хостов, или имени шаблона, ну и т.п.
    my $ITEM_TO_SITE;

    # типы элементов и код+шаблоны для формирования имен файлов, куда какой тип элементов сохранять
    my $CFG_ITEM_TYPES = {
        'service'                               => q[$fname = sprintf qq[%s/services-site%d.cfg],            $CFG_OUT,                            $site;],
        'host'                                  => q[$fname = sprintf qq[%s/hosts-site%d.cfg],               $CFG_OUT,                            $site;],
        'command'                               => q[$fname = sprintf qq[%s/commands.cfg], $CFG_OUT                                                    ;],
        'templates'                             => q[$fname = sprintf qq[%s/templates-site%d.cfg],           $DIR_TEMPLATES_OUT->{$site},         $site;],
        'templates_for_another_site'            => q[$fname = sprintf qq[%s/templates-site%d.cfg],           $DIR_TEMPLATES_OUT->{$another_site}, $site;],
        'templates_for_another_site_OK'         => q[$fname = sprintf qq[%s/templates-site%d\-OK.cfg],       $DIR_TEMPLATES_OUT->{$another_site}, $site;],
        'templates_for_another_site_CRITICAL'   => q[$fname = sprintf qq[%s/templates-site%d\-CRITICAL.cfg], $DIR_TEMPLATES_OUT->{$another_site}, $site;],
        'templates_for_another_site_CRITICAL'   => q[$fname = sprintf qq[%s/templates-site%d\-CRITICAL.cfg], $DIR_TEMPLATES_OUT->{$another_site}, $site;],
    };

    my %FILE_HANDLERS; # здесь будет список уже открытых файлов, типа <file name> => <FILE_HANDLER>. Чтобы не открывать каждый раз

    # еще глобальная переменная, заполняется внутри build_hostgroups(), для определения площадки по имени хоста.
    # в т.ч. рекурсивным вызовом. Кривовато, зато быстро. :)
    my $SITE_BY_HOST;

#### / OPTIONS

# итоговые хранилища для вывода в файл
my $list_hosts;
my $list_services;
my $list_hostgroups;
my $list_commands;

# "сырой" конфиг, считанный модулем Nagios
my $config;

# получаем список файлов - рекурсивный проход по всем каталогам внутри $CFG_IN, кроме файлов в самом каталоге
my @flist = split /\n/, `find $CFG_IN/*/ -name '*.cfg'`;

#### идем по найденным файлам
    for my $config_file_name ( @flist )
    {
        #### DEBUG OUTPUT
        if($DEBUG) {
            print qq[\n#######################\n$config_file_name\n#######################\n\n];
        }

        $config = Nagios::Object::Config->new();

        $config->parse( $FILE_HOSTGROUPS_OUT );# для каждого файла читаем обновленный список групп хостов, дополнять тоже будем его же
        $config->parse( $config_file_name );

        &main( $config, $config_file_name ); # ну и собственно разбор/перетасовка конфига
    }

    #### DEBUG OUTPUT
        if($DEBUG) {
            print "\n";
            print "СВЯЗКА ITEM_TO_SITE : ", Dumper( $ITEM_TO_SITE );
        }
    #### / DEBUG OUTPUT

#### / ####

sub main
{
    my $config = shift || return undef;
    my $config_file_name = shift || '$config_file_name - ???';

    # это для отсеивания дублей имен: поля name, host_name, hostgroup_name должны быть уникальными в пределах одной площадки (файла)
    my $already_exists = {};    # глобальность только в пределах одного файла
    sub name_already_exists
    {
        my $item_type = shift || return 0; # $cfg_item->{_nagios_setup_key} || template
        my $item = shift || return 0;
        my $already_exists =  shift || return 0;
        my $callfromline =  shift || '???';

        # уникальные идентификаторы элементов конфига
        my $ITEM_ID_NAME = {
            template    => 'name',
            host        => 'host_name',
            hostgroup   => 'hostgroup_name',
            command     => 'command_name',
        };

        # неизвестный тип пункта конфига
        return 0 if not defined $ITEM_ID_NAME->{ $item_type };

        # отбрасываем дубли записей
        my $key_type = $ITEM_ID_NAME->{ $item_type };
        if( defined( $item->{$key_type} ) and $item->{$key_type} ne '' )
        {
            # гнусный хардкод :(
            # для шаблонов уникализация должна делаться по связке name + use, для остальных как задумывалось
            # my $item_uniq_key = $item_type eq 'template' ? $item->{name}.' '.$item->{use} : $item->{$key_type};
            my $item_uniq_key = $item->{$key_type};

            if( defined $already_exists->{ $item_type }->{ $key_type }->{ $item_uniq_key } )
            {
                #### DEBUG OUTPUT
                if($DEBUG) {
                    printf qq[\t($callfromline) пропущен дубль "%s.%s = %s"\n], $item_type, $key_type, $item_uniq_key;
                }

                return 1;
            }
            $already_exists->{ $item_type }->{ $key_type }->{ $item_uniq_key } = 1; # запоминаем имя
        }
        return 0;
    }

    # в принципе, здесь можно и без этого хардкода ( типа ...->all_objects() ), но так читабельнее
    $list_hosts          = $config->list_hosts() || [];
    $list_services       = $config->list_services() || [];
    $list_hostgroups     = $config->list_hostgroups() || [];
    $list_commands       = $config->list_commands() || [];

################ from prev version ################

        # строим список групп и подгрупп хостов
        &build_hostgroups( undef, undef );

        #### DEBUG OUTPUT
        print Dumper( $SITE_BY_HOST );

        # определяемся с номером площадки
        my $PLOSCHADKA = &get_site_orig( $list_hosts, $SITE_BY_HOST );
        my $DRUGAYA_PLOSCHADKA = $PLOSCHADKA == 1 ? 2 : 1;

        # die $PLOSCHADKA."\n";

################ / from prev version ################

    # строим список соответствия: хост|подгруппа => площадка
    &build_links_item_to_site( undef, undef );

    # сюда все складываем
    my $configs;
    for my $cfg_item ( @{ $list_hosts }, @{ $list_services }, @{ $list_hostgroups }, @{ $list_commands } )
    {

        if( $OLD_VERSION )
        {
            ###### Вертать все взад!!!
            $cfg_item->{sites} = [ $PLOSCHADKA ]; # определяемся с площадкой раз и навсегда
        }
        else
        {
            $cfg_item->{_nagios_setup_key} = lc $cfg_item->{_nagios_setup_key}; # и нафига нужно было писать это с заглавной буквы?

            # номер площадки должен определяться ОТДЕЛЬНО для КАЖДОГО элемента конфига (хост, шаблон, сервис и т.п.)
            # соответственно имена файлов/каталогов должны быть для каждого ЭЛЕМЕНТА свои
            # получаем площадки (массив номеров), к которым принадлежит этот элемент
            $cfg_item->{sites} = &get_site( $cfg_item, $ITEM_TO_SITE );
        }

        #### DEBUG OUTPUT
            if($DEBUG) {
                my $Data_Dumper_Indent = $Data::Dumper::Indent;
                my $Data_Dumper_Terse  = $Data::Dumper::Terse ;
                $Data::Dumper::Indent = 0; # не делать отступы/переводы строк
                $Data::Dumper::Terse = 1; # убрать "$VAR = "

                my $item_name = $cfg_item->{host_name} || $cfg_item->{hostgroup_name} || $cfg_item->{command_name} || $cfg_item->{name} || undef;

                printf( qq[%s : Имя %s : Площадки %s\n],
                    $cfg_item->{_nagios_setup_key},
                    Dumper( $item_name ),
                    Dumper( $cfg_item->{sites} ),
                );
                $Data::Dumper::Indent = $Data_Dumper_Indent;
                $Data::Dumper::Terse  = $Data_Dumper_Terse ;
            }
        #### DEBUG OUTPUT

        # шаблон или экземпляр?
        # ШАБЛОН хоста или сервиса
        if( defined( $cfg_item->{register} ) and $cfg_item->{register} == 0)    # шаблон
        {
            # > ... шаблоны хостов/сервисов. Разделяются на два
            #
            # - формируем новый item из таких параметров
            #
            #     name    = site<1|2>-<исходный use>
            #     use     = <исходный use>
            #     register= <исходный register>
            #
            # - в старом item заменяем
            #     use     = site<1|2>-<исходный use>
            #
            if( $cfg_item->{use} =~ m{^(windows\-server)|(linux\-server)|(local\-service)$} )
            {
                my $orig_use = $cfg_item->{use}; # а то оно ниже перезаписывается на измененное
                for my $site ( @{ $cfg_item->{sites} } )
                {
                    my $item_new = {
                        name       => ( sprintf qq[site%d-%s], $site, $orig_use ),
                        register   => $cfg_item->{register},
                        use        => $orig_use,
                        # это служебные
                        _nagios_setup_key => $cfg_item->{_nagios_setup_key},
                        sites      => $cfg_item->{sites},
                    };

                    $cfg_item->{use} = ( sprintf qq[site%d-%s], $site, $orig_use );

                    # контроль на дубль нового шаблона - вдруг с таким именем уже есть
                    next if &name_already_exists( 'template', $item_new, $already_exists, __LINE__ ); # дубли режем

                    push @{ $configs->{templates} }, $item_new;
                }
            }

            # контроль дублей шаблонов хостов
            next if &name_already_exists( 'template', $cfg_item, $already_exists, __LINE__ ); # дубли режем

            push @{ $configs->{templates} }, &build_item($cfg_item);

        }
        # ЭКЗЕМПЛЯР
        else
        {
            # контроль дублей экземпляров
            next if &name_already_exists( $cfg_item->{_nagios_setup_key}, $cfg_item, $already_exists ); # дубли режем

            push @{ $configs->{ $cfg_item->{_nagios_setup_key} } }, &build_item($cfg_item);
        }
    }

    # дополнительные перетасовки шаблонов
    # > В описание шаблонов site1-local-service и site1-windows-server производятся  изменения:
    for my $cfg_item ( @{ $configs->{templates} } )
    {

        my $item_new = clone( $cfg_item );

        ## НЕ НАДО! или надо? пока нет
        # # заменяем номер площадки на противоположную
        # for( my $i=0; $i<scalar(@{ $item_new->{sites} }); $i++ ) # нах оптимальность
        # {
        #     $item_new->{sites}->[$i] = $item_new->{sites}->[$i] == 1 ? 2 : 1;
        # }

        # if( $cfg_item->{name} =~ m{^((site[0-9]+\-local\-service)|(site[0-9]+\-windows\-server))$} )
        if( $cfg_item->{name} =~ m{^site[0-9]+\-} )
        {
            # добавляем поля
            $item_new->{active_checks_enabled}  = 0;
            $item_new->{max_check_attempts}     = 1;
            $item_new->{normal_check_interval}  = 5;
            $item_new->{retry_check_interval}   = 1;


            push @{ $configs->{templates_for_another_site} }, clone($item_new);

            # Далее файл templates-site1.cfg в этой же папке копируется еще в два файла:
            #   templates-site1-CRITICAL.cfg и templates-site1-OK.cfg
            push @{ $configs->{templates_for_another_site_OK} }, clone($item_new);

            # > в файле templates-site1-CRITICAL.cfg ... значение ... active_checks_enabled меняется на 1
            $item_new->{active_checks_enabled}  = 1;
            push @{ $configs->{templates_for_another_site_CRITICAL} }, clone($item_new);
        }
        else
        {
            push @{ $configs->{templates_for_another_site} },           clone($item_new);
            push @{ $configs->{templates_for_another_site_OK} },        clone($item_new);
            push @{ $configs->{templates_for_another_site_CRITICAL} },  clone($item_new);
        }
    }


    #### вывод в файлы

        # группы хостов всегда пишутся в один файл (пока?)
        &write_file( $FILE_HOSTGROUPS_OUT, &build_config( $configs->{hostgroup} ) ) or die "Can't write $FILE_HOSTGROUPS_OUT!";

        # идем по списку типов
        for my $cfg_item_type ( keys %{ $CFG_ITEM_TYPES } )
        {
            # идем по списку элементов типа
            for my $cfg_item ( @{ $configs->{$cfg_item_type} } )
            {
                #### DEBUG OUTPUT
                    # if($DEBUG) {
                    #     my $Data_Dumper_Indent = $Data::Dumper::Indent;
                    #     my $Data_Dumper_Terse  = $Data::Dumper::Terse ;
                    #     $Data::Dumper::Indent = 0; # не делать отступы/переводы строк
                    #     $Data::Dumper::Terse = 1; # убрать "$VAR = "

                    #     my $item_name = $cfg_item->{host_name} || $cfg_item->{hostgroup_name} || $cfg_item->{name} || undef;

                    #     $config_file_name =~ s{^.*?/([^/]+)$}{$1};

                    #     printf( qq[%s : %s : %s : %s : %s\n],
                    #         $config_file_name,
                    #         $cfg_item_type,
                    #         $cfg_item->{_nagios_setup_key},
                    #         Dumper( $item_name ),
                    #         Dumper( $cfg_item->{sites} ),
                    #     );

                    #     $Data::Dumper::Indent = $Data_Dumper_Indent;
                    #     $Data::Dumper::Terse  = $Data_Dumper_Terse ;
                    # }
                #### DEBUG OUTPUT

                # идем по списку площадок, к которым относится элемент
                for my $site ( @{ $cfg_item->{sites} } )
                {

                    # для каждой площадки формируем свое имя файла
                    my $another_site = $site == 1 ? 2 : 1;
                    my $fname; eval $CFG_ITEM_TYPES->{ $cfg_item_type }; die qq[File name for '$cfg_item_type' not formed: ] . $@ if $@;

                    # если файл еще не открыт - если существует, удаляем его, и вновь открываем (создаем), на запись и добавление
                    if( not defined $FILE_HANDLERS{$fname} )
                    {
                        system(qq[rm -f $fname]) if -e $fname;
                        open( $FILE_HANDLERS{$fname}, "+>", $fname ) or die "cannot open $fname: $!";

                        #### DEBUG OUTPUT
                        # print qq[\t$fname\n];

                    }
                    binmode $FILE_HANDLERS{$fname};
                    select $FILE_HANDLERS{$fname}; $|=1; select STDOUT;

                    # элементы с полями name и use, содержащими "site1", не должны попадать в конфиги
                    # с именами файлов, содержащими "site2", и наоборот
                    if( defined( $cfg_item->{name}) and $cfg_item->{name} =~ m{^site(?<site>[0-9]+)} )
                    {
                        if ($site != $+{site})
                        {
                             #### DEBUG OUTPUT
                             print qq[Remove:\tsite: $site\tname: $cfg_item->{name}   \t(use: $cfg_item->{use})\n];
                             next;
                        };
                    };
                    if( defined( $cfg_item->{use}) and $cfg_item->{use} =~ m{^site(?<site>[0-9]+)} )
                    {
                        if ($site != $+{site})
                        {
                             #### DEBUG OUTPUT
                             print qq[Remove:\tsite: $site\tuse: $cfg_item->{use}   \t(name: $cfg_item->{name})\n];
                             next;
                        };
                    };

                    # формируем текст элемента и дописываем его в конец файла
                    my $out = sprintf qq[define %s{\n], $cfg_item->{_nagios_setup_key};
                    for my $param ( sort keys %{ $cfg_item } )
                    {
                        # эти поля там не нужны
                        next if $param =~ m{^(?:_nagios_setup_key|sites)$}o;

                        my $value = $cfg_item->{$param};
                        next if not defined $value;

                        $out .= ( sprintf qq[\t$param %s\n], $value );
                    }
                    $out .= qq[}\n\n];

                    print {$FILE_HANDLERS{$fname}} $out;

                }
            }
        }
    #### / вывод в файлы


    return 1;
}

# строит массив номеров площадок, к которым относится элемент.
# (по host_name или hostgroup_name)
sub get_site
{
    my $cfg_item = shift || return 0;
    my $ITEM_TO_SITE = shift || return 0;

    my %tmpsites;    # для уникализации
    my $sites = [];

    # принадлежность элемента к хосту или группе хостов определяется по полям
    # host_name или hostgroup_name
    # !!!!! любой элемент может принадлежать не одному хосту или группе, а нескольким!
    # (т.е. значение host_name или hostgroup_name может быть массивом)
    #   дальнейшее уже неверно
    # Поэтому он может принадлежать и нескольким площадкам!!!!
    # !!!! и его надо записать во все файлы площадок, к которым он принадлежит
    # Т.о. $site = это ссылка на МАССИВ!!!

    my $item_name = $cfg_item->{host_name} || $cfg_item->{hostgroup_name} || $cfg_item->{command_name} || $cfg_item->{name} || undef;

    if ( defined $item_name )
    {
        # передан ШАБЛОН хоста или сервиса
        if( defined( $cfg_item->{register} ) and $cfg_item->{register} == 0 )
        {
            # для шаблонов немного сложнее
            $sites = &get_template_sites( $item_name );
        }
        else
        {
            # приводим к массиву для единообразия
            $item_name = [ $item_name ] if not ref $item_name;
            for my $name ( @$item_name )
            {
                $tmpsites{ $ITEM_TO_SITE->{ $name } } = 1 if defined $ITEM_TO_SITE->{ $name };
            }
            # сюда пишем найденные площадки
            $sites = [ sort keys( %tmpsites ) ];
        }
    }

    $sites = [ 1 ] if not scalar @$sites;

    return $sites || [ 1 ];  # если в конфиге нет хостов, перечисленных в $CFG_IN/hostgroups-sites.cfg,
                           # выбирается площадка 1 (site1)
}

# для простановки шаблонам номера площадки требуется проход по экземплярам:
#   ищем экземпляр, у которого в поле use упомянут этот шаблон, то этому шаблону ДОБАВЛЯЕМ site от экземпляра.
#   Если еще какой-то экземпляр С ДРУГОЙ ПЛОЩАДКИ ссылается на этот же шаблон -
#   у шаблона получается список площадок, куда его писать.
sub get_template_sites {
    my $template_name = shift || return [];

    my %tmpsites;    # для уникализации
    my @template_sites;

    # идем по экземплярам (хостов или сервисов)
    for my $cfg_item ( @{ $list_hosts }, @{ $list_services } )
    {
        $cfg_item->{_nagios_setup_key} = lc $cfg_item->{_nagios_setup_key}; # и нафига нужно было писать это с заглавной буквы?

        # нашли экземпляр хоста или сервиса, в котором есть упоминание переданного шаблона
        if(
            ( not defined( $cfg_item->{register} ) or $cfg_item->{register} != 0 )
            and
            defined( $cfg_item->{use} )
            and
            $cfg_item->{use} eq $template_name
        )
        {
            my $item_name = $cfg_item->{host_name} || $cfg_item->{hostgroup_name} || $cfg_item->{name} || undef;
            # приводим к массиву для единообразия
            $item_name = [ $item_name ] if not ref $item_name;
            for my $name ( @$item_name )
            {
                $tmpsites{ $ITEM_TO_SITE->{ $name } } = 1 if defined $ITEM_TO_SITE->{ $name };
            }
        }
    }

    # сюда пишем все найденные площадки
    for my $site ( sort keys %tmpsites )
    {
        push @template_sites, $site;
    }
    return( scalar @template_sites ? [ @template_sites ] : [ -1 ] );
}



# строит список вида "<host|subgroup>name => site[12]" (идентификаторы площадок (site1 и site2))
# используется ДЛЯ ОПРЕДЕЛЕНИЯ ПЛОЩАДКИ (в итоге имени файла) для каждого элемента конфига.
sub build_links_item_to_site
{
    # идем по группам хостов
    for my $cfg_item ( @{ $list_hostgroups } )
    {
        $cfg_item->{_nagios_setup_key} = lc $cfg_item->{_nagios_setup_key}; # и нафига нужно было писать это с заглавной буквы?

        #### DEBUG OUTPUT
        # if($DEBUG) {
        #     printf qq['%s'\n], $cfg_item->{hostgroup_name};
        # }

        # заполняем только для групп с именами типа site[12] (т.е. только для "площадок")
        my $THIS_IS_MAIN_SITE = $cfg_item->{hostgroup_name} =~ m{^site([0-9]+)$} ? 1 : 0;
        my $SITE_NUMBER = $1 || 1;

        # сами основные площадки вносим
        $ITEM_TO_SITE->{ $cfg_item->{hostgroup_name} } = $1 if $THIS_IS_MAIN_SITE;

        my $members = $cfg_item->members();
        next if not defined $members;

        #### DEBUG OUTPUT
        # if($DEBUG) {
        #     print "\tmembers :\n";
        # }

        # если в списке только один пункт - список зачем-то превращается в скаляр. фиксим, бо мне тут массив нужен.
        $members = [ $members ] if ref( $members ) ne 'ARRAY';
        for my $host_name ( @$members )
        {

            #### DEBUG OUTPUT
            # if($DEBUG) {
            #     printf "\t\t%s\n", $host_name;
            # }

            $ITEM_TO_SITE->{ $host_name } = $SITE_NUMBER if $THIS_IS_MAIN_SITE;
        }

        my $include_groups = $cfg_item->hostgroup_members();
        next if not defined $include_groups;

        #### DEBUG OUTPUT
        # if($DEBUG) {
        #     print "\tinclude groups:\n";
        # }

        for my $group_name ( @$include_groups )
        {
            #### DEBUG OUTPUT
            # if($DEBUG) {
            #     printf "\t\t%s\n", $group_name;
            # }

            $ITEM_TO_SITE->{ $group_name } = $SITE_NUMBER if $THIS_IS_MAIN_SITE;

            # проходим по включенной [под]группе и вытаскиваем ее хосты в список хостов включающей группы
            # print Dumper( $config->{hostgroup_index} ); exit; # ппц...
            my $members = $config->{hostgroup_index}{ $group_name }[0]{members};
            if( defined $members )
            {
                # если в списке только один пункт - список зачем-то превращается в скаляр. фиксим, бо мне тут массив нужен.
                $members = [ $members ] if ref( $members ) ne 'ARRAY';
                for my $host ( @{ $members } )
                {
                    #### DEBUG OUTPUT
                    # if($DEBUG) {
                    #     printf "\t\t\t%s\n", $host;
                    # }

                    $ITEM_TO_SITE->{ $host } = $SITE_NUMBER if $THIS_IS_MAIN_SITE;
                }
            }
        }
    }

    return 1;
}

# из непустых ключей строит хэш, содержащий один пункт конфига (define{ ... })
sub build_item
{
    my $cfg_item = shift || return {};

    my $item;
    for my $param ( sort keys %{ $cfg_item } )
    {
        my $value = $cfg_item->{$param};
        next if not defined $value;

        if( $param eq 'sites' ) # это служебное поле, значение не трогать, в вывод оно и так не попадет
        {
            $item->{$param} = $value;
            next;
        }

        # фильтруем, чтобы в конфиг-файлы попадали только текстовые данные
        if( not ref( $value ) or ref( $value ) eq 'SCALAR' )
        {
            $item->{$param} = $value;
        }
        elsif( ref( $value ) eq 'ARRAY' )
        {
            $item->{$param} = join( ',', @$value );
        }
    }

    return $item;
}

# по переданному списку пунктов строит текст конфига для записи в файл
sub build_config
{
    my $config = shift || return '';

    my $out = '';
    for my $cfg_item ( @$config )
    {
        $out .= ( sprintf qq[define %s{\n], $cfg_item->{_nagios_setup_key} );
        for my $param ( sort keys %{ $cfg_item } )
        {
            next if $param =~ m{^(?:_nagios_setup_key|sites)$}o; # не нужно это там

            my $value = $cfg_item->{$param};
            next if not defined $value;

            $out .= ( sprintf qq[\t$param %s\n], $value );
        }
        $out .= qq[}\n\n];
    }
    return $out;
}

sub write_file
{
    my $fname = shift   || do{ print "File name required!\n"; return 0; };
    my $content = shift || do{ print "Empty content, file '$fname' left untouched\n"; return 0; };

    open FH, '>'.$fname || do{ print "Error opening '$fname': " . $!; return 0; };
    # это отключение буферизации, здесь не нужно: my $tmps = select(); select FH; $|=1; select $tmps;
    print FH $content;
    close FH;

    return 1;
}


##############################################################
sub get_site_orig
{
    my $list_hosts = shift || return 0;
    my $SITE_BY_HOST = shift || return 0;

    for my $cfg_item ( @{ $list_hosts } )
    {
        next if defined( $cfg_item->{register} ) and $cfg_item->{register} == 0;    # шаблоны пропускаем
        if( defined $SITE_BY_HOST->{ $cfg_item->{host_name} } )
        {
            # print "$cfg_item->{host_name}\n";
            return substr( $SITE_BY_HOST->{ $cfg_item->{host_name} }, -1 )
        }
    }
    return 1;   # В случае, если найдутся хосты, которые не определены в $CFG_IN/hostgroups-sites.cfg,
                # то такие хосты приписываются к site1
}

# это нужно ТОЛЬКО ДЛЯ ОПРЕДЕЛЕНИЯ ПЛОЩАДКИ по имени хоста.
# строит список вида "hostname => groupname", при этом в groupname пишет ТОЛЬКО РОДИТЕЛЬСКИЕ ГРУППЫ САМОГО НИЖНЕГО УРОВНЯ,
# т.е. именно идентификаторы площадок (site1 и site2)
sub build_hostgroups
{
    my $groupname = shift || undef;
    my $parent_groupname = shift || undef;

    # Идем по всем группам хостов
    for my $cfg_item ( @{ $list_hostgroups } )
    {
        # если передано имя группы - смотрим только в ней
        next if defined($groupname) and $groupname ne $cfg_item->{hostgroup_name};

        # какого хрена! если в списке только один пункт - список зачем-то превращается в скаляр. фиксим, бо мне тут массив нужен.
        $cfg_item->{members} = [ $cfg_item->{members} ] if defined( $cfg_item->{members} ) and ref( $cfg_item->{members} ) ne 'ARRAY';
        $cfg_item->{hostgroup_members} = [ $cfg_item->{hostgroup_members} ] if defined( $cfg_item->{hostgroup_members} ) and ref( $cfg_item->{hostgroup_members} ) ne 'ARRAY';

        # в конфиге явно указаны хосты-члены группы -
        if( defined( $cfg_item->{members} ) and scalar( @{ $cfg_item->{members} } ) )
        {
            for my $member ( @{ $cfg_item->{members} } )
            {
                # при этом в кач-ве groupname используем ТОЛЬКО РОДИТЕЛЬСКИЕ ГРУППЫ САМОГО НИЖНЕГО УРОВНЯ,
                # т.е. именно идентификаторы площадок (site1 и site2)
                if( defined $parent_groupname )
                {
                    $SITE_BY_HOST->{$member} = $parent_groupname;
                }
                elsif( not $SITE_BY_HOST->{$member} )
                {
                    $SITE_BY_HOST->{$member} = $cfg_item->{hostgroup_name};
                }
            }
        }

        # если передано имя группы - смотрим ТОЛЬКО EE ЧЛЕНОВ
        next if defined($groupname) and $groupname ne $cfg_item->{hostgroup_name};

        # в конфиге указаны также подгруппы, входящие в группу
        if( defined( $cfg_item->{hostgroup_members} ) and scalar( @{ $cfg_item->{hostgroup_members} } ) )
        {
            # вытаскиваем хосты - членов этих подгрупп
            for my $subgroup_name ( @{ $cfg_item->{hostgroup_members} } )
            {
                # устраняем бесконечную рекурсию в случае ошибки конфига (указание этой же группы в списке своих подгрупп)
                next if defined($groupname) and $subgroup_name eq $groupname;
                # !!!!!!!!!!!!!!!! рекурсия !!!!!!!!!!!!
                &build_hostgroups( $subgroup_name, $cfg_item->{hostgroup_name} );
            }
        }

    }

    return( $SITE_BY_HOST );
}

#!/usr/bin/perl -w

use strict;
use Clone 'clone';
use File::Copy qw(copy);

use lib("./lib");
use Nagios::Config;

use Data::Dumper;

#### OPTIONS
    ###################################################################
    my $BASE_DIR    = qq[/Users/dalp/Projects/Nagios_cfg_files/etc];
    ###################################################################

    my $CFG_IN      = qq[$BASE_DIR/objects];
    my $CFG_OUT     = qq[$BASE_DIR/runtime]; mkdir $CFG_OUT if not -d $CFG_OUT;

    my $FILE_HOSTGROUPS_IN  = qq[$CFG_IN/hostgroups-sites.cfg];
    my $FILE_HOSTGROUPS_OUT = qq[$CFG_OUT/hostgroups-sites.cfg];

    my $DIR_TEMPLATES_OUT = {
        1 => qq[$CFG_OUT/local.config1],
        2 => qq[$CFG_OUT/local.config2],
    };

    # создать каталоги если нету
    mkdir $DIR_TEMPLATES_OUT->{1} if not -d $DIR_TEMPLATES_OUT->{1};
    mkdir $DIR_TEMPLATES_OUT->{2} if not -d $DIR_TEMPLATES_OUT->{2};

    # т.к. файл с группами будет пополняться с каждым обработанным конфигом,
    # то каждый раз мы должны открывать уже пополненный файл, а не входной.
    # копируем входной в выходной и в дальнейшем используем только выходной, и для чтения, и для записи
    copy $FILE_HOSTGROUPS_IN, $FILE_HOSTGROUPS_OUT;

    # еще глобальная переменная, заполняется внутри build_hostgroups(), для определения площадки по имени хоста.
    # в т.ч. рекурсивным вызовом. Кривовато, зато быстро. :)
    my $SITE_BY_HOST;
#### / OPTIONS

# промежуточные хранилища для читабельности
my $list_hosts;
my $list_services;
my $list_hostgroups;
my $config;

# получаем список файлов - рекурсивный проход по всем каталогам внутри $CFG_IN, кроме файлов в самом каталоге
my @flist = split /\n/, `find $CFG_IN/*/ -name '*.cfg'`;

#### идем по найденным файлам
    for my $fname ( @flist )
    {
        #### DEBUG OUTPUT
        print qq[$fname\n];

        $config = Nagios::Object::Config->new();

        $config->parse( $FILE_HOSTGROUPS_OUT );# для каждого файла читаем обновленный список групп хостов, дополнять тоже будем его же
        $config->parse( $fname );

        &main( $config ); # ну и собственно разбор/перетасовка конфига
    }
#### / ####

sub main
{
    my $config = shift || return undef;

    # это для отсеивания дублей имен: поля name, host_name, hostgroup_name должны быть уникальными в пределах одной площадки (файла)
    my $already_exists = {};    # глобальность только в пределах одного файла
    sub name_already_exists
    {
        my $item_type = shift || return 0; # $cfg_item->{_nagios_setup_key} || template
        my $item = shift || return 0;
        my $already_exists =  shift || return 0;

        # уникальные идентификаторы элементов конфига
        my $ITEM_ID_NAME = {
            template    => 'name',
            host        => 'host_name',
            hostgroup   => 'hostgroup_name',
        };

        # неизвестный тип пункта конфига
        return 0 if not defined $ITEM_ID_NAME->{ $item_type };

        my $key_type = $ITEM_ID_NAME->{ $item_type };
        if( defined( $item->{$key_type} ) and $item->{$key_type} ne '' )
        {
            if( defined $already_exists->{ $item_type }->{ $key_type }->{ $item->{$key_type} } )
            {
                #### DEBUG OUTPUT
                printf qq[\tпропущен дубль "%s.%s = %s"\n], $item_type, $key_type, $item->{$key_type};
                return 1;
            }
            $already_exists->{ $item_type }->{ $key_type }->{ $item->{$key_type} } = 1; # запоминаем имя
        }
        return 0;
    }

    # в принципе, здесь можно и без этого хардкода ( типа ...->all_objects() ), но так читабельнее
    $list_hosts          = $config->list_hosts();
    $list_services       = $config->list_services();
    $list_hostgroups     = $config->list_hostgroups();

    # строим список групп и подгрупп хостов
    &build_hostgroups( undef, undef );

    #### DEBUG OUTPUT
    print Dumper( $SITE_BY_HOST );

    # определяемся с номером площадки
    my $site = &get_site( $list_hosts, $SITE_BY_HOST );
    my $another_site = $site == 1 ? 2 : 1;

    # теперь определяемся с именами файлов/каталогов, содержащих номер площадки
    my $FILE_TEMPLATES_OUT  = sprintf qq[%s/templates-site%d.cfg], $DIR_TEMPLATES_OUT->{$site}, $site;
    my $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE             = sprintf qq[%s/templates-site%d.cfg],           $DIR_TEMPLATES_OUT->{$another_site}, $site;
    my $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE_OK          = sprintf qq[%s/templates-site%d\-OK.cfg],       $DIR_TEMPLATES_OUT->{$another_site}, $site;
    my $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE_CRITICAL    = sprintf qq[%s/templates-site%d\-CRITICAL.cfg], $DIR_TEMPLATES_OUT->{$another_site}, $site;
    my $FILE_HOSTS_OUT      = sprintf qq[$CFG_OUT/hosts-site%d.cfg], $site;
    my $FILE_SERVICES_OUT   = sprintf qq[$CFG_OUT/services-site%d.cfg], $site;

    # сюда все складываем
    my $configs;
    for my $cfg_item ( @{ $list_hosts }, @{ $list_services } , @{ $list_hostgroups } )
    {
        $cfg_item->{_nagios_setup_key} = lc $cfg_item->{_nagios_setup_key}; # и нафига нужно было писать это с заглавной буквы?

        # шаблон или экземпляр?
        if( defined( $cfg_item->{register} ) and $cfg_item->{register} == 0)    # шаблон
        {
            # > ... шаблоны хостов. Разделяются на два.
            if( $cfg_item->{use} =~ m{^(windows\-server)|(linux\-server)|(local\-service)$} )
            {
                my $item_new = {
                    name       => ( sprintf qq[site%d-%s], $site, $cfg_item->{use} ),
                    register   => $cfg_item->{register},
                    use        => $cfg_item->{use},
                    _nagios_setup_key => $cfg_item->{_nagios_setup_key},
                };

                # контроль дублей
                next if &name_already_exists( 'template', $item_new, $already_exists ); # дубли режем

                push @{ $configs->{templates} }, $item_new;
                $cfg_item->{use} = $item_new->{name};
            }
            push @{ $configs->{templates} }, &build_item($cfg_item);
        }
        else
        {
            # контроль дублей
            next if &name_already_exists( $cfg_item->{_nagios_setup_key}, $cfg_item, $already_exists ); # дубли режем

            push @{ $configs->{ $cfg_item->{_nagios_setup_key} } }, &build_item($cfg_item);
        }
    }

    # дополнительные перетасовки шаблонов
    # > В описание шаблонов site1-local-service и site1-windows-server производятся  изменения:
    for my $cfg_item ( @{ $configs->{templates} } )
    {
        my $item_new = clone( $cfg_item );

        if( $cfg_item->{name} =~ m{^((site[0-9]+\-local\-service)|(site[0-9]+\-windows\-server))$} )
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
        &write_file( $FILE_TEMPLATES_OUT,                           &build_config( $configs->{templates}                           ) ) or die "Can't write $FILE_TEMPLATES_OUT!";
        &write_file( $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE,          &build_config( $configs->{templates_for_another_site}          ) ) or die "Can't write $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE!";
        &write_file( $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE_OK,       &build_config( $configs->{templates_for_another_site_OK}       ) ) or die "Can't write $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE_OK!";
        &write_file( $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE_CRITICAL, &build_config( $configs->{templates_for_another_site_CRITICAL} ) ) or die "Can't write $FILE_TEMPLATES_OUT_FOR_ANOTHER_SITE_CRITICAL!";
        &write_file( $FILE_HOSTGROUPS_OUT,                          &build_config( $configs->{hostgroup}                           ) ) or die "Can't write $FILE_HOSTGROUPS_OUT!";
        &write_file( $FILE_SERVICES_OUT,                            &build_config( $configs->{service}                             ) ) or die "Can't write $FILE_SERVICES_OUT!";
        &write_file( $FILE_HOSTS_OUT,                               &build_config( $configs->{host}                                ) ) or die "Can't write $FILE_HOSTS_OUT!";
    #### / вывод в файлы

    return 1;
}

sub get_site
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

# из непустых ключей строит хэш, содержащий один пункт конфига (define{ ... })
sub build_item
{
    my $cfg_item = shift || return {};

    my $item;
    for my $param ( sort keys %{ $cfg_item } )
    {
        my $value = $cfg_item->{$param};
        next if not defined $value;

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
            next if $param eq '_nagios_setup_key'; # не нужно это там

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

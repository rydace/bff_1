create or replace procedure aml_clients_bck.check_all_clients_rsm(
    --In parameters
    p_divisor   in number default 1, --делитель
    p_remainder in number default 0 --остаток
    --Out parameters
) is
  /*
  Раддим Смайлов. 01.12.2019.
  Процедура проверки всей КБ по ЧС
  Я запарился исправлять существующие. Так как в них логика из Цесны, ЕАБРа, и других банков.
  Написал свою реализацию.

  Проверка в двух направлениях.
  Проверяем записи в списках по списку клиента. Список клиента в СОЛР.
  Проверяем клиента по записям в списках. Список ЧС в СОЛР.

  В проверке можно поделить данные на потоки.
  Если делитель к примеру 5. То процедуру надо вызвать 5 раз, с остатками 4,3,2,1,0
  */

  --Переменные имя объекта и ошибки
  l_object_name   varchar2(500 char) := 'CHECK_ALL_CLIENTS_RSM';
  l_error_code    varchar2(4000 char);
  l_error_message varchar2(4000 char);
  l_check_type    varchar2(500 char) := 'CLIENT_OFFLINE';

  --Переменные количество на проверку
  l_count_checked    number := 0;
  l_count_clients    number := 0;
  l_count_bl_records number := 0;

  --Переменная количество обновленных строк
  l_update_count number := 0;

  --Переменные проверки (check_black_list)
  l_result        number;
  l_out_comment   varchar2(4000 char);
  l_out_percent   number;
  l_out_tablename varchar2(4000 char);
  l_out_recordid  varchar2(4000 char);
  l_out_dict      varchar2(4000 char);
  l_out_name_dict varchar2(4000 char);
  l_out_curcor    sys_refcursor;

  --Переменные курсора (check_black_list)
  cr_id                number;
  cr_list_name         varchar2(4000 char);
  cr_similar_percent   number;
  cr_dict_tablename    varchar2(4000 char);
  cr_dict_recordid     number;
  cr_comments          varchar2(4000 char);
  cr_client_name       varchar2(4000 char);
  cr_coof              number;
  cr_count_100_percent number;
  cr_dict_desc         varchar2(4000 char);
  cr_ref_id            varchar2(4000 char);
  cr_file_hash         varchar2(4000 char);

  --Переменная детализации (set_check_detail)
  l_out_inserted  varchar2(4000 char);
  l_temp_inserted varchar2(4000 char);
begin
  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name || '_START',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Начало проверки по ЧС. Поток: ' || p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name ||
                                                                '_FIRST',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Начало проверки новых/изменных или ранее получивших ошибку при проверке клиентов по ЧС. Поток: ' ||p_divisor || '-' ||p_remainder,
                                              in_bs_id       => 1);

  select count(*)
    into l_count_clients
    from aml_user_bck.clients c
    left join aml_user_bck.client_check cc
      on (c.id = cc.client_id)
   where mod(c.id, p_divisor) = p_remainder --Делим на потоки
     and (cc.bl_check_date is null --Дата провекри пустая
          or c.date_update > cc.bl_check_date --Или дата обновления карточки новее чем дата проверки
          --or cc.check_black_list in (0, 3) --Или статус проверки ошибка
          );

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name || '_FIRST',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Количество записей для проверки: ' || l_count_clients ||
                                                                '. Поток: ' || p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);

  --Обнуляем переменную
  l_count_checked := 0;

  --Проверка новых или изменных клиентов по ЧС
  for recin in (
      select c.id, c.translit_name, c.idn, c.client_type_id
         from aml_user_bck.clients c
         left join aml_user_bck.client_check cc
           on (c.id = cc.client_id)
        where mod(c.id, p_divisor) = p_remainder --Делим на потоки
          and (cc.bl_check_date is null --Дата провекри пустая
               or c.date_update > cc.bl_check_date --Или дата обновления карточки новее чем дата проверки
               --or cc.check_black_list in (0, 3) --Или статус проверки ошибка
               )
  ) loop

    begin
      --Обнуляем переменные
      cr_id                := null;
      cr_list_name         := null;
      cr_similar_percent   := null;
      cr_dict_tablename    := null;
      cr_dict_recordid     := null;
      cr_comments          := null;
      cr_client_name       := null;
      cr_coof              := null;
      cr_count_100_percent := null;
      cr_dict_desc         := null;
      cr_ref_id            := null;
      cr_file_hash         := null;
      l_out_inserted       := 'NO';
      l_temp_inserted      := 'NO';

      l_result := check_black_list(in_name          => recin.translit_name,
                                   in_dict_id       => null,
                                   in_check_type    => l_check_type,                                   
                                   in_white_list_id => 1,
                                   in_client_id     => recin.idn,
                                   in_client_type   => recin.client_type_id,
                                   in_sub_date      => null,
                                   in_eq_type       => null,
                                   in_isone         => null,
                                   out_comment      => l_out_comment,
                                   out_percent      => l_out_percent,
                                   out_tablename    => l_out_tablename,
                                   out_recordid     => l_out_recordid,
                                   out_dict         => l_out_dict,
                                   out_name_dict    => l_out_name_dict,
                                   out_curcor       => l_out_curcor,
                                   iteration        => null);

      if l_result = 1 then
        loop
          fetch l_out_curcor
            into cr_id,
                 cr_list_name,
                 cr_similar_percent,
                 cr_dict_tablename,
                 cr_dict_recordid,
                 cr_comments,
                 cr_client_name,
                 cr_coof,
                 cr_count_100_percent,
                 cr_dict_desc,
                 cr_ref_id,
                 cr_file_hash;
          exit when l_out_curcor%notfound;

          set_check_detail_rsm(in_client_id  => recin.id,
                               in_check_type => l_check_type,
                               in_comments   => cr_comments,
                               in_percent    => cr_similar_percent,
                               in_list_name  => cr_list_name,
                               in_dict_desc  => cr_dict_desc,
                               in_dict_id    => get_dict_id(cr_dict_tablename),
                               in_list_id    => cr_dict_recordid,
                               in_status     => 1,
                               out_inserted  => l_temp_inserted);

          if l_temp_inserted = 'YES' then
            l_out_inserted := 'YES';
          end if;
        end loop;
      end if;

      --Анализируем и проставляем статус
      update aml_user_bck.client_check t set
             --t.check_black_list = decode(l_out_inserted, 'YES', 1, nvl(t.check_black_list, l_result)),
             t.check_black_list = decode(l_out_inserted, 'YES', decode(t.check_black_list, 2, t.check_black_list, 1), nvl(t.check_black_list, l_result)),
             t.bl_check_date    = sysdate,
             t.bl_check_comment = l_out_comment,
             t.bl_user_name     = user
       where client_id = recin.id;

      l_update_count := sql%rowcount;

      if l_update_count = 0 then
        insert into aml_user_bck.client_check
          (client_id,
           check_black_list,
           bl_check_date,
           bl_check_comment,
           bl_comment,
           change_date,
           bl_user_name)
        values
          (recin.id, l_result, sysdate, l_out_comment, null, sysdate, user);
      end if;

      commit;
    exception
      when others then
        l_error_code    := sqlcode;
        l_error_message := sqlerrm;

        aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'ERROR',
                                                    in_action      => l_object_name || '_EXCEPTION1',
                                                    in_ref_object  => 'CLIENTS',
                                                    in_ref_id      => recin.id,
                                                    in_description => 'Ошибка проверки по ЧС. Поток: ' || p_divisor || '-' || p_remainder || chr(10) ||
                                                                      l_error_code || '-' || l_error_message || chr(10) ||
                                                                      'id: ' || recin.id || chr(10) ||
                                                                      'translit_name: ' || recin.translit_name || chr(10) ||
                                                                      'idn: ' || recin.idn || chr(10) ||
                                                                      'client_type_id: ' || recin.client_type_id,
                                                    in_bs_id       => 1);

        pkg_main.ins_log_error(p_object_name            => l_object_name,
                               p_tag_1                  => 'EXCEPTION WHEN OTHERS',
                               p_tag_2                  => 'EXCEPTION1',
                               p_code_error             => l_error_code,
                               p_message_error          => l_error_message,
                               p_format_error_backtrace => dbms_utility.format_error_backtrace,
                               p_format_error_stack     => dbms_utility.format_error_stack,
                               p_format_call_stack      => dbms_utility.format_call_stack,
                               p_full_info              => 'p_divisor: ' || p_divisor || chr(10) ||
                                                           'p_remainder: ' || p_remainder || chr(10) || 
                                                           'id: ' || recin.id || chr(10) ||
                                                           'translit_name: ' || recin.translit_name || chr(10) ||
                                                           'idn: ' || recin.idn || chr(10) ||
                                                           'client_type_id: ' || recin.client_type_id
                               );

    end;

    l_count_checked := l_count_checked + 1;

    if mod(l_count_checked, 10000) = 0 then
      aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                                  in_action      => l_object_name || '_FIRST',
                                                  in_ref_object  => 'CLIENTS',
                                                  in_ref_id      => 0,
                                                  in_description => 'Количество проверенных клиентов: ' || l_count_checked ||
                                                                    '. Поток: ' || p_divisor || '-' || p_remainder,
                                                  in_bs_id       => 1);
      if aml_user_bck.pkg_processes.Status($$plsql_unit) = -1 then
        aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                                    in_action      => l_object_name || '_FIRST',
                                                    in_ref_object  => 'CLIENTS',
                                                    in_ref_id      => 0,
                                                    in_description => 'Досрочное завершение проверки клиентов!',
                                                    in_bs_id       => 1);
      end if;
    end if;

  end loop;

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name || '_FIRST',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Количество проверенных клиентов: ' || l_count_checked ||
                                                                '. Поток: ' || p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name || '_FIRST',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Конец проверки новых/изменных или ранее получивших ошибку при проверке клиентов по ЧС. Поток: ' ||
                                                                p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);

  /*--------------------------------------------------------------------------------------------------------------------*/

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name || '_SECOND',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Начало проверки новых или изменных записей в списке по ЧС. Поток: ' ||
                                                                p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);

  select count(*)
    into l_count_bl_records
    from dict_black_list           dbl,
         directory_list            dl,
         dict_list_check_types     dlct,
         check_type_directory_link ctdl
   where mod(dbl.id, p_divisor) = p_remainder --Делим на потоки
     and dbl.dict_id = dl.id
     and dbl.status = 0 --Статус одобренные
     and dbl.is_active = 1 --Активные
     and dl.is_active = 1 --Активные
     and dl.table_name = ctdl.directory_name
     and ctdl.is_active = 1 --Активные
     and dlct.id = ctdl.check_type_id
     and dlct.name = l_check_type
     and (dbl.last_check_date is null --Дата проверки пустая
          or dbl.last_modify_date > dbl.last_check_date --Дата изменения списка больше чем проверки
          );

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name ||
                                                                '_SECOND',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Количество записей для проверки: ' || l_count_bl_records ||
                                                                '. Поток: ' || p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);

  --Обнуляем переменную
  l_count_checked := 0;

  for recin in (select dbl.id,
                       dbl.translit_name,
                       dbl.client_id,
                       dbl.dict_id,
                       dbl.note,
                       dbl.subject_type,
                       dl.table_name,
                       dl.dict_description,
                       dl.default_min_percent
                  from dict_black_list           dbl,
                       directory_list            dl,
                       dict_list_check_types     dlct,
                       check_type_directory_link ctdl
                 where mod(dbl.id, p_divisor) = p_remainder --Делим на потоки
                   and dbl.dict_id = dl.id
                   and dbl.status = 0 --Статус одобренные
                   and dbl.is_active = 1 --Активные
                   and dl.is_active = 1 --Активные
                   and dl.table_name = ctdl.directory_name
                   and ctdl.is_active = 1 --Активные
                   and dlct.id = ctdl.check_type_id
                   and dlct.name = l_check_type
                   and (dbl.last_check_date is null --Дата проверки пустая
                        or dbl.last_modify_date > dbl.last_check_date --Дата изменения списка больше чем проверки
                        )
  ) loop
    begin

      --Обнуляем переменные
      cr_id                := null;
      cr_list_name         := null;
      cr_similar_percent   := null;
      cr_dict_tablename    := null;
      cr_dict_recordid     := null;
      cr_comments          := null;
      cr_client_name       := null;
      cr_coof              := null;
      cr_count_100_percent := null;
      cr_dict_desc         := null;
      cr_ref_id            := null;
      cr_file_hash         := null;
      l_out_inserted       := 'NO';
      l_temp_inserted      := 'NO';

      --Проверка по наименованию.
      if trim(recin.translit_name) is not null then

        l_result := get_similar_clients(in_name        => recin.translit_name,
                                        in_min_percent => 95,
                                        in_isone       => null,
                                        in_client_type => recin.subject_type,
                                        in_citizenship => null,
                                        out_comment    => l_out_comment,
                                        out_percent    => l_out_percent,
                                        out_curcor     => l_out_curcor,
                                        iteration      => null);

        if l_result = 1 then
          loop
            fetch l_out_curcor
              into cr_id,
                   cr_list_name,
                   cr_similar_percent,
                   cr_comments,
                   cr_coof,
                   cr_count_100_percent;
            exit when l_out_curcor%notfound;

            set_check_detail_rsm(in_client_id  => cr_id,
                                 in_check_type => l_check_type,
                                 in_comments   => cr_comments,
                                 in_percent    => cr_similar_percent,
                                 in_list_name  => recin.translit_name,
                                 in_dict_desc  => recin.dict_description,
                                 in_dict_id    => recin.dict_id,
                                 in_list_id    => recin.id,
                                 in_status     => 1,
                                 out_inserted  => l_temp_inserted);

            if l_temp_inserted = 'YES' then
              --Анализируем и проставляем статус
              update aml_user_bck.client_check t set
                     --t.check_black_list = decode(l_temp_inserted, 'YES', 1, nvl(t.check_black_list, l_result)),
                     t.check_black_list = decode(l_temp_inserted, 'YES', decode(t.check_black_list, 2, t.check_black_list, 1), nvl(t.check_black_list, l_result)),
                     t.bl_check_date    = sysdate,
                     t.bl_check_comment = l_out_comment,
                     t.bl_user_name     = user
               where client_id = cr_id;

              l_update_count := sql%rowcount;

              if l_update_count = 0 then
                insert into aml_user_bck.client_check
                  (client_id,
                   check_black_list,
                   bl_check_date,
                   bl_check_comment,
                   bl_comment,
                   change_date,
                   bl_user_name)
                values
                  (cr_id,
                   l_result,
                   sysdate,
                   l_out_comment,
                   null,
                   sysdate,
                   user);
              end if;

              commit;

            end if;
          end loop;

        end if;

      end if;

      --Проверка по ИИН/БИН
      if recin.client_id is not null and
        --Не проверяем по следующим ИИН/БИН. Согласовано с Гульжан и Александром
         recin.client_id not in ('000000000000',
                                 '111111111111',
                                 '222222222222',
                                 '333333333333',
                                 '444444444444',
                                 '555555555555',
                                 '666666666666',
                                 '777777777777',
                                 '888888888888',
                                 '999999999999') then
        for rec_client in (
           select c.id,
                  c.translit_name,
                  c.idn,
                  c.client_type_id
              from aml_user_bck.clients c
             where c.idn = recin.client_id
        ) loop

          l_out_comment := substr('Процент совпадения: ' || 100 || chr(10) ||
                                  'Проверяли наименование: ' || rec_client.translit_name || chr(10) ||
                                  'Проверяли ИИН/БИН: ' || rec_client.idn || chr(10) || 
                                  'Наименование в списке: ' || recin.translit_name || chr(10) ||
                                  'ИИН/БИН в списке: ' || recin.client_id || chr(10) || 
                                  'Совпало с: ' || recin.client_id || chr(10) ||
                                  'Справочник: ' || recin.dict_description || ' (' || recin.table_name || ')' || chr(10) ||
                                  'ID записи в справочнике: ' || recin.id || chr(10) || 
                                  'Комментарий: ' || recin.note,
                                  1,
                                  4000);

          set_check_detail_rsm(in_client_id  => rec_client.id,
                               in_check_type => l_check_type,
                               in_comments   => l_out_comment,
                               in_percent    => 100,
                               in_list_name  => recin.client_id,
                               in_dict_desc  => recin.dict_description,
                               in_dict_id    => recin.dict_id,
                               in_list_id    => recin.id,
                               in_status     => 1,
                               out_inserted  => l_out_inserted);

          --Анализируем и проставляем статус
          update aml_user_bck.client_check t set
                 --t.check_black_list = decode(l_out_inserted, 'YES', 1, nvl(t.check_black_list, 1)),
                 t.check_black_list = decode(l_out_inserted, 'YES', decode(t.check_black_list, 2, t.check_black_list, 1), nvl(t.check_black_list, l_result)),
                 t.bl_check_date    = sysdate,
                 t.bl_check_comment = l_out_comment,
                 t.bl_user_name     = user
           where client_id = rec_client.id;

          l_update_count := sql%rowcount;

          if l_update_count = 0 then
            insert into aml_user_bck.client_check
              (client_id,
               check_black_list,
               bl_check_date,
               bl_check_comment,
               bl_comment,
               change_date,
               bl_user_name)
            values
              (rec_client.id,
               1,
               sysdate,
               l_out_comment,
               null,
               sysdate,
               user);
          end if;

          commit;

        end loop;
      end if;

      --Обновляем дату проверки
      update dict_black_list
         set last_check_date = sysdate
       where id = recin.id;

      --Обновляем дату проверки
      update directory_list
         set last_check_date = sysdate
       where id = recin.dict_id;

      commit;

    exception
      when others then
        l_error_code    := sqlcode;
        l_error_message := sqlerrm;

        aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'ERROR',
                                                    in_action      => l_object_name ||
                                                                      '_EXCEPTION2',
                                                    in_ref_object  => 'DICT_BLACK_LIST',
                                                    in_ref_id      => recin.id,
                                                    in_description => 'Ошибка проверки по КБ. Поток: ' || p_divisor || '-' || p_remainder || chr(10) ||
                                                                      l_error_code || '-' || l_error_message || chr(10) ||
                                                                      'id: ' || recin.id || chr(10) ||
                                                                      'translit_name: ' || recin.translit_name || chr(10) ||
                                                                      'client_id: ' || recin.client_id || chr(10) ||
                                                                      'dict_id: ' || recin.dict_id || chr(10) ||
                                                                      'note: ' || recin.note || chr(10) ||
                                                                      'subject_type: ' || recin.subject_type || chr(10) ||
                                                                      'table_name: ' || recin.table_name || chr(10) ||
                                                                      'dict_description: ' || recin.dict_description ||chr(10) ||
                                                                      'default_min_percent: ' || recin.default_min_percent,
                                                    in_bs_id       => 1);

        pkg_main.ins_log_error(p_object_name            => l_object_name,
                               p_tag_1                  => 'EXCEPTION WHEN OTHERS',
                               p_tag_2                  => 'EXCEPTION2',
                               p_code_error             => l_error_code,
                               p_message_error          => l_error_message,
                               p_format_error_backtrace => dbms_utility.format_error_backtrace,
                               p_format_error_stack     => dbms_utility.format_error_stack,
                               p_format_call_stack      => dbms_utility.format_call_stack,
                               p_full_info              => 'p_divisor: ' || p_divisor || chr(10) ||
                                                           'p_remainder: ' || p_remainder || chr(10) || 
                                                           'id: ' || recin.id || chr(10) ||
                                                           'translit_name: ' || recin.translit_name || chr(10) ||
                                                           'client_id: ' || recin.client_id || chr(10) ||
                                                           'dict_id: ' || recin.dict_id || chr(10) ||
                                                           'note: ' || recin.note || chr(10) ||
                                                           'subject_type: ' || recin.subject_type || chr(10) ||
                                                           'table_name: ' || recin.table_name || chr(10) ||
                                                           'dict_description: ' || recin.dict_description || chr(10) ||
                                                           'default_min_percent: ' || recin.default_min_percent);

    end;

    l_count_checked := l_count_checked + 1;

    if mod(l_count_checked, 10000) = 0 then
      aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                                  in_action      => l_object_name || '_SECOND',
                                                  in_ref_object  => 'CLIENTS',
                                                  in_ref_id      => 0,
                                                  in_description => 'Количество проверенных записей в списке по ЧС: ' || l_count_checked ||
                                                                    '. Поток: ' || p_divisor || '-' || p_remainder,
                                                  in_bs_id       => 1);
      if aml_user_bck.pkg_processes.Status($$plsql_unit) = -1 then
        aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                                    in_action      => l_object_name || '_SECOND',
                                                    in_ref_object  => 'CLIENTS',
                                                    in_ref_id      => 0,
                                                    in_description => 'Досрочное завершение проверки списков!',
                                                    in_bs_id       => 1);
      end if;
    end if;
  end loop;

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name || '_SECOND',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Количество проверенных записей в списке по ЧС: ' || l_count_checked ||
                                                                '. Поток: ' || p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name ||
                                                                '_SECOND',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Конец проверки новых или изменных записей в списке по ЧС. Поток: ' ||
                                                                p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);

  aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'NOTIFICATION',
                                              in_action      => l_object_name ||
                                                                '_FINISH',
                                              in_ref_object  => 'CLIENTS',
                                              in_ref_id      => 0,
                                              in_description => 'Конец проверки по ЧС. Поток: ' || p_divisor || '-' || p_remainder,
                                              in_bs_id       => 1);
exception
  when others then
    l_error_code    := sqlcode;
    l_error_message := sqlerrm;

    aml_user_bck.pkg_load_utils.bs_load_log_ins(in_action_type => 'ERROR',
                                                in_action      => l_object_name ||
                                                                  '_EXCEPTION',
                                                in_ref_object  => 'CLIENTS',
                                                in_ref_id      => 0,
                                                in_description => 'Ошибка проверки по ЧС. Поток: ' || p_divisor || '-' || p_remainder || chr(10) ||
                                                                  l_error_code || '-' || l_error_message,
                                                in_bs_id       => 1);

    pkg_main.ins_log_error(p_object_name            => l_object_name,
                           p_tag_1                  => 'EXCEPTION WHEN OTHERS',
                           p_tag_2                  => null,
                           p_code_error             => l_error_code,
                           p_message_error          => l_error_message,
                           p_format_error_backtrace => dbms_utility.format_error_backtrace,
                           p_format_error_stack     => dbms_utility.format_error_stack,
                           p_format_call_stack      => dbms_utility.format_call_stack,
                           p_full_info              => 'p_divisor: ' || p_divisor || chr(10) ||
                                                       'p_remainder: ' || p_remainder);
end;

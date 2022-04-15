open! Dune_engine
open Stdune
open Dune_file

module T = struct
  type is_component_of_a_group_but_not_the_root =
    { group_root : Path.Build.t
    ; stanzas : Stanza.t list Dir_with_dune.t option
    }

  type t =
    | Generated
    | Source_only of Source_tree.Dir.t
    | (* Directory not part of a multi-directory group *)
        Standalone of
        Source_tree.Dir.t * Stanza.t list Dir_with_dune.t
    | (* Directory with [(include_subdirs x)] where [x] is not [no] *)
        Group_root of
        Source_tree.Dir.t
        * (Loc.t * Include_subdirs.qualification)
        * Stanza.t list Dir_with_dune.t
    | (* Sub-directory of a [Group_root _] *)
        Is_component_of_a_group_but_not_the_root of
        is_component_of_a_group_but_not_the_root
end

include T

type enclosing_group =
  | No_group
  | Group_root of Path.Build.t

let current_group dir = function
  | Generated | Source_only _ | Standalone _ -> No_group
  | Group_root _ -> Group_root dir
  | Is_component_of_a_group_but_not_the_root { group_root; _ } ->
    Group_root group_root

let get_include_subdirs stanzas =
  List.fold_left stanzas ~init:None ~f:(fun acc stanza ->
      match stanza with
      | Include_subdirs (loc, x) ->
        if Option.is_some acc then
          User_error.raise ~loc
            [ Pp.text
                "The 'include_subdirs' stanza cannot appear more than once"
            ];
        Some (loc, x)
      | _ -> acc)

let check_no_module_consumer stanzas =
  List.iter stanzas ~f:(fun stanza ->
      match stanza with
      | Library { buildable; _ }
      | Executables { buildable; _ }
      | Tests { exes = { buildable; _ }; _ } ->
        User_error.raise ~loc:buildable.loc
          [ Pp.text
              "This stanza is not allowed in a sub-directory of directory with \
               (include_subdirs unqualified)."
          ]
          ~hints:[ Pp.text "add (include_subdirs no) to this file." ]
      | _ -> ())

module DB = struct
  type nonrec t =
    { stanzas_per_dir : Dune_file.Stanzas.t Dir_with_dune.t Path.Build.Map.t
    ; fn : (Path.Build.t, t) Memo.Table.t
    }

  let stanzas_in db ~dir = Path.Build.Map.find db.stanzas_per_dir dir

  let get db ~dir =
    let open Memo.O in
    let get ~dir = Memo.exec db.fn dir in
    let enclosing_group ~dir =
      match Path.Build.parent dir with
      | None -> Memo.return No_group
      | Some parent_dir -> get ~dir:parent_dir >>| current_group parent_dir
    in
    (match Path.Build.drop_build_context dir with
    | None -> Memo.return None
    | Some dir -> Source_tree.find_dir dir)
    >>= function
    | None -> (
      let+ enclosing_group = enclosing_group ~dir in
      match enclosing_group with
      | No_group -> Generated
      | Group_root group_root ->
        Is_component_of_a_group_but_not_the_root { stanzas = None; group_root })
    | Some st_dir -> (
      let project_root = Source_tree.Dir.project st_dir |> Dune_project.root in
      let build_dir_is_project_root =
        Path.Build.drop_build_context_exn dir |> Path.Source.equal project_root
      in
      match stanzas_in db ~dir with
      | None -> (
        if build_dir_is_project_root then Memo.return (Source_only st_dir)
        else
          let+ enclosing_group = enclosing_group ~dir in
          match enclosing_group with
          | No_group -> Source_only st_dir
          | Group_root group_root ->
            Is_component_of_a_group_but_not_the_root
              { stanzas = None; group_root })
      | Some d -> (
        match get_include_subdirs d.data with
        | Some (loc, Include mode) ->
          Memo.return (T.Group_root (st_dir, (loc, mode), d))
        | Some (_, No) -> Memo.return (Standalone (st_dir, d))
        | None -> (
          if build_dir_is_project_root then Memo.return (Standalone (st_dir, d))
          else
            let+ enclosing_group = enclosing_group ~dir in
            match enclosing_group with
            | Group_root group_root ->
              check_no_module_consumer d.data;
              Is_component_of_a_group_but_not_the_root
                { stanzas = Some d; group_root }
            | No_group -> Standalone (st_dir, d))))

  let make ~stanzas_per_dir =
    (* CR-someday aalekseyev: This local recursive module is a bit awkward. In
       the future the plan is to move the memo to the top-level to make it less
       awkward (and to dissolve the [DB] datatype). *)
    let module M = struct
      module rec Res : sig
        val t : t
      end = struct
        let t =
          { stanzas_per_dir
          ; fn = Memo.create "get-dir-status" ~input:(module Path.Build) Fn.get
          }
      end

      and Fn : sig
        val get : Path.Build.t -> T.t Memo.t
      end = struct
        let get dir = get Res.t ~dir
      end
    end in
    M.Res.t

  let get db ~dir = Memo.exec db.fn dir
end

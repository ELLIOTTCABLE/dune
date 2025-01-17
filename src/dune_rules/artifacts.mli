open Import

module Bin : sig
  type t

  (** Force the computation of the internal list of binaries. This is exposed as
      some error checking is only performed during this computation and some
      errors will go unreported unless this computation takes place. *)
  val force : t -> unit Memo.t

  val bin_dir_basename : Filename.t

  (** [local_bin dir] The directory which contains the local binaries viewed by
      rules defined in [dir] *)
  val local_bin : Path.Build.t -> Path.Build.t

  (** A named artifact that is looked up in the PATH if not found in the tree If
      the name is an absolute path, it is used as it. *)
  val binary : t -> ?hint:string -> loc:Loc.t option -> string -> Action.Prog.t Memo.t

  val binary_available : t -> string -> bool Memo.t

  module Local : sig
    type t

    val equal : t -> t -> bool
    val create : Path.Build.Set.t -> t
  end

  val create : context:Context.t -> local_bins:Local.t Memo.Lazy.t -> t
  val add_binaries : t -> dir:Path.Build.t -> File_binding.Expanded.t list -> t
end

module Public_libs : sig
  type t =
    { context : Context.t
    ; public_libs : Lib.DB.t
    }
end

type t = private
  { public_libs : Public_libs.t
  ; bin : Bin.t
  }

val create : Context.t -> public_libs:Lib.DB.t -> local_bins:Bin.Local.t Memo.Lazy.t -> t

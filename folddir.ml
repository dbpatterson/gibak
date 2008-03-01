open Util
open Unix

module type IGNORE =
sig
  type t
  val init : string -> t
  val update : t -> string -> t
  val is_ignored : ?debug:bool -> t -> string -> bool
end

let join a b = if a <> "" && b <> "" then a ^ "/" ^ b else a ^ b

type 'a fold_acc = Continue of 'a | Prune of 'a

module type S =
sig
  type ignore_info
  val fold_directory :
    ?debug:bool -> ('a -> string -> Unix.stats -> 'a fold_acc) -> 'a ->
    string -> ?ign_info:ignore_info -> string -> 'a
end

module Make(M : IGNORE) : S with type ignore_info = M.t =
struct
  type ignore_info = M.t

  let rec fold_directory ?(debug=false) f acc base ?(ign_info = M.init base) path =
    let acc = ref acc in
    let ign_info = M.update ign_info path in
    let dir = join base path in
      try
        do_finally (opendir dir) closedir
          (fun d ->
             try
               while true do
                 match readdir d with
                     "." | ".." -> ()
                     | n when M.is_ignored ~debug ign_info n -> ()
                     | n ->
                         let n = join path n in
                         let stat = lstat (join base n) in
                           match f !acc n stat with
                             | Continue x ->
                                 acc := x;
                                 if stat.st_kind = S_DIR then
                                   acc := fold_directory ~debug f ~ign_info
                                            !acc base n
                             | Prune x -> acc := x
               done;
               assert false
             with End_of_file -> ());
        !acc
      with Unix.Unix_error _ -> !acc
end

module Ignore_none : IGNORE =
struct
  type t = unit
  let init _ = ()
  let update () _ = ()
  let is_ignored ?debug () _ = false
end

module Gitignore : IGNORE =
struct
  open Printf

  type glob_type = Accept | Deny
  type patt =
      Simple of string | Noslash of string
    | Complex of string | Endswith of string
  type glob = glob_type * patt
  type t = { base : string; levels : (string * glob list) list }

  external fnmatch : bool -> string -> string -> bool = "perform_fnmatch" "noalloc"

  let string_of_patt = function Simple s | Noslash s | Complex s | Endswith s -> s

  let has_wildcard s =
    let rec loop s i max =
      if i < max then
        match String.unsafe_get s i with
            '*' | '?' | '[' | '{' -> true
            | _ -> loop s (i+1) max
      else false
    in loop s 0 (String.length s)

  let patt_of_string s =
    if String.contains s '/' then
      Complex s
    else let suff = String.sub s 1 (String.length s - 1) in
      if s.[0] = '*' && not (has_wildcard suff) then
        Endswith suff
      else if has_wildcard s then
        Noslash s
      else
        Simple s

  let glob_of_string s = match s.[0] with
      '!' -> (Accept, (patt_of_string (String.sub s 1 (String.length s - 1))))
    | _ -> (Deny, patt_of_string s)

  let collect_globs l =
    let rec aux acc = function
        [] -> acc
      | line::tl ->
          if line = "" || line.[0] = '#' then aux acc tl
          else aux (glob_of_string line :: acc) tl
    in aux [] l

  let read_gitignore path =
    try
      collect_globs
        (do_finally (open_in (join path ".gitignore")) close_in
           (fun is ->
              let l = ref [] in
                try
                  while true do
                    l := input_line is :: !l
                  done;
                  assert false
                with End_of_file -> !l) )
    with Sys_error _ -> []

  let init path = { base = path; levels = [] }

  let update t dir =
    let globs = read_gitignore dir in
      { base = dir; levels = (Filename.basename dir, globs) :: t.levels }

  type path = Path of string * string list

  let path_of_string s = Path (s, [])
  let string_of_path (Path (basename, l)) = String.concat "/" (l @ [basename])
  let push x (Path (basename, l)) = Path (basename, x :: l)
  let basename (Path (basename, _)) = basename

  let glob_matches patt path = match patt with
      Simple s -> s = basename path
    | Endswith s ->
        let fname = basename path in
        let l1 = String.length s in
        let l2 = String.length fname in
          if l2 < l1 then false else strneq s 0 fname (l2 - l1)
    | Noslash s -> fnmatch false s (basename path)
    | Complex s -> fnmatch true s (string_of_path path)

  let is_ignored ?(debug=false) t fname =
    let rec aux path = function
      | [] -> false
      | (dname, globs)::tl ->
        let ign = List.fold_left
          (fun s (ty, patt) ->
            if glob_matches patt path then
              (match ty with
                  Accept ->
                    if debug then
                        eprintf "ACCEPT %S (matched %S) at %S\n"
                          (string_of_path path) (string_of_patt patt) t.base;
                    `Kept
                | Deny ->
                    if debug then
                        eprintf "DENY %S (matched %S) at %S\n"
                          (string_of_path path) (string_of_patt patt) t.base;
                    `Ignored)
            else s)
          `Dontknow globs
        in match ign with
          | `Dontknow -> aux (push dname path) tl
          | `Ignored -> true
          | `Kept -> false
    in fname = ".git" || aux (path_of_string fname) t.levels
end

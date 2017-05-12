(* sandbox.ml
   Copyright 2017 Inria
   author: Damien Doligez
*)

open Printf

let opcdir = Sys.getenv "OPAMCHECKDIR"
let sandbox = Filename.concat opcdir "sandbox"
let bin = Filename.concat sandbox "bin"
let path = sprintf "%s:%s" bin (Sys.getenv "PATH")
let fetch = "fetch %{checksum}% %{url}% %{out}%"
let gitdir = Filename.concat sandbox "dotopam-git"
let opamroot = Filename.concat gitdir "dotopam"
let repo = Filename.concat sandbox "opam-repository"
let failure_file = Filename.concat gitdir "opamcheck-fail"
let opam =
  sprintf "PATH='%s' OPAMFETCH='%s' OPAMROOT='%s' OPAMNO=true opam "
    path fetch opamroot

let run cmd =
  eprintf "# %s\n" cmd; flush stderr;
  Sys.command cmd

let run0 cmd =
  let res = run cmd in
  if res <> 0 then
    failwith (sprintf "command failed with result %d: %s" res cmd)

type result = OK | Failed of (string * string) list

(** encoding must be done in the right order: "..x" before ".x" *)
let encode_compare s1 s2 =
  let rec loop i =
    if i >= String.length s1 then
      if i >= String.length s2 then 0 else -1
    else if i >= String.length s2 then 1
    else if s1.[i] = s2.[i] then loop (i + 1)
    else Pervasives.compare s1.[i] s2.[i]
  in
  loop 0

(** rename all ".xxx" to "..xxx" *)
let rec encode dir =
  let f x =
    let xx = Filename.concat dir x in
    if Sys.is_directory xx then encode xx;
    if x.[0] = '.' then Sys.rename xx (Filename.concat dir ("." ^ x));
  in
  let entries = Sys.readdir dir in
  Array.sort encode_compare entries;
  Array.iter f entries

(* decoding must be done in the reverse order of encoding *)
let decode_compare s1 s2 = encode_compare s2 s1

(** remove all ".[^.]xxx" and rename all "..xxx" to ".xxx" *)
let rec decode dir =
  let f x =
    let xx = Filename.concat dir x in
    if x.[0] = '.' && x.[1] != '.' then begin
      run0 (sprintf "/bin/rm -rf %s" xx)
    end else begin
      if Sys.is_directory xx then decode xx;
      if x.[0] = '.' then begin
        let newname = String.sub x 1 (String.length x - 1) in
        Sys.rename xx (Filename.concat dir newname)
      end
    end
  in
  let entries = Sys.readdir dir in
  Array.sort decode_compare entries;
  Array.iter f entries

let rec parse_failure_file ic acc =
  match Version.split_name_version (input_line ic) with
  | (name, Some vers) -> parse_failure_file ic ((name, vers) :: acc)
  | (name, None) -> assert false
  | exception End_of_file -> List.rev acc

let read_failure () =
  if Sys.file_exists failure_file then begin
    let ic = open_in failure_file in
    let res = Failed (parse_failure_file ic []) in
    close_in ic;
    res
  end else
    OK

let write_failure l =
  let oc = open_out failure_file in
  List.iter (fun (p, v) -> fprintf oc "%s.%s\n" p v) l;
  close_out oc

let save msg l =
  let status = match read_failure () with OK -> "ok" | _ -> "failed" in
  encode opamroot;
  let f nv = Version.name_version nv ^ "\n" in
  let packs = String.concat "" (List.map f l) in
  let tag = "p" ^ Digest.to_hex (Digest.string packs) in
  run0 (sprintf "git -C %s checkout -b %s" gitdir tag);
  run0 (sprintf "git -C %s add -A" gitdir);
  run0 (sprintf "git -C %s commit --allow-empty -m '(%s) %s -> %s'"
          gitdir status msg tag);
  decode opamroot

let restore l =
  let packs = String.concat " " (List.map Version.name_version l) in
  let tag = "p" ^ Digest.to_hex (Digest.string packs) in
  if run (sprintf "git -C %s checkout %s" gitdir tag) = 0 then begin
    run0 (sprintf "git -C %s clean -d -f -x" gitdir);
    decode opamroot;
    true
  end else
    false

(** [l2] must be a suffix of [l1]. Return the initial part of [l1], reversed *)
let rev_diff l1 l2 =
  let rec loop l1 l2 =
    match l1, l2 with
    | _, [] -> l1
    | h1 :: t1, h2 :: t2 -> loop t1 t2
    | [], _ -> assert false
  in
  loop (List.rev l1) (List.rev l2)

let play_solution ocaml l =
  let l = ("compiler", ocaml) :: l in
  let rl = List.rev l in
  let rec find_start l =
    match l with
    | [] -> None
    | h :: t -> if restore l then Some l else find_start t
  in
  let rec play l acc =
    match read_failure () with
    | Failed l -> Failed l
    | OK ->
       begin match l with
       | [] -> OK
       | (pack, vers) :: t ->
          let cmd =
            if pack = "compiler" then
              sprintf "switch %s" vers
            else
              sprintf "install %s.%s" pack vers
          in
          let packs_done = ((pack, vers) :: acc) in
          if run (sprintf "%s %s" opam cmd) <> 0 then write_failure packs_done;
          save cmd packs_done;
          play t packs_done
       end
  in
  match find_start rl with
  | None ->
     run0 (sprintf "/bin/rm -rf %s" gitdir);
     run0 (sprintf "/bin/mkdir -p %s" opamroot);
     run0 (sprintf "%s init --no-setup default %s" opam repo);
     run0 (sprintf "git -C %s init" gitdir);
     run0 (sprintf "echo '!*' >%s" (Filename.concat gitdir ".gitignore"));
     save "initial state" [];
     play l []
  | Some suff -> play (rev_diff rl suff) suff

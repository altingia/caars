(*
# File: Phyldog.ml
# Created by: Carine Rey
# Created on: March 2016
#
#
# Copyright 2016 Carine Rey
# This software is a computer program whose purpose is to assembly
# sequences from RNA-Seq data (paired-end or single-end) using one or
# more reference homologous sequences.
# This software is governed by the CeCILL license under French law and
# abiding by the rules of distribution of free software.  You can  use,
# modify and/ or redistribute the software under the terms of the CeCILL
# license as circulated by CEA, CNRS and INRIA at the following URL
# "http://www.cecill.info".
# As a counterpart to the access to the source code and  rights to copy,
# modify and redistribute granted by the license, users are provided only
# with a limited warranty  and the software's author,  the holder of the
# economic rights,  and the successive licensors  have only  limited
# liability.
# In this respect, the user's attention is drawn to the risks associated
# with loading,  using,  modifying and/or developing or reproducing the
# software by the user in light of its specific status of free software,
# that may mean  that it is complicated to manipulate,  and  that  also
# therefore means  that it is reserved for developers  and  experienced
# professionals having in-depth computer knowledge. Users are therefore
# encouraged to load and test the software's suitability as regards their
# requirements in conditions enabling the security of their systems and/or
# data to be ensured and,  more generally, to use and operate it in the
# same conditions as regards security.
# The fact that you are presently reading this means that you have had
# knowledge of the CeCILL license and that you accept its terms.
*)

open Core
open Bistro.Std
open Bistro.EDSL
open Bistro_bioinfo.Std
open Commons

type phyldog_configuration = [`phyldog_configuration] directory

type phylotree

let phyldog_script ~family ~config_dir ~results_species ~tree ~results_genes =
  let vars = [
    "LIST_SPECIES", config_dir // "listSpecies.txt" ;
    "TREE", dep tree ;
    "RESULTS_SPECIES", results_species ;
    "NP", string "2" ;
    "GENERAL_OPTIONS", config_dir // "GeneralOptions.txt" ;
    "GENERAL_OPTIONS_CAT", config_dir // "GeneralOptions_cat.txt" ;
    "CONFIG_DIR", config_dir ;
    "RESULTS_GENES", results_genes ;
    "FAMILY", string family ;
  ]
  in
  bash_script vars {|
    nb_species=`wc -l < $LIST_SPECIES`
    echo $nb_species
    filename=`basename $TREE`
    family=${FAMILY}
    touch ${RESULTS_SPECIES}${family}.orthologs.txt
    touch ${RESULTS_SPECIES}${family}.events.txt
    cat $GENERAL_OPTIONS $CONFIG_DIR/*opt > $GENERAL_OPTIONS_CAT
    echo output.file=${family} >> $GENERAL_OPTIONS_CAT
    wc -l $TREE
    cp $TREE $CONFIG_DIR
    if [ $nb_species -gt 2 ]
    then
     phyldog_light likelihood.evaluator=LIBPLL2 param=$GENERAL_OPTIONS_CAT
     ls
     cut -f 2 ${family}_orthologs.txt > ${RESULTS_SPECIES}${family}.orthologs.txt
     cut -f 1,3- -d "," ${family}_events.txt > ${RESULTS_SPECIES}${family}.events.txt
     cp ${family}_reconciled.tree  ${RESULTS_GENES}${family}.ReconciledTree
    else
     nw2nhx.py $TREE ${RESULTS_GENES}${family}.ReconciledTree
    fi
|}


let phyldog_by_fam
    ?(descr="")
    ?datatype
    ?dataformat
    ?sptreefile
    ?topospecies
    ?dlopt
    ?max_gap
    ?equgenomes
    ?topogene
    ?timelimit
    ?(memory = 1)
    ~family
    ~threads
    ~link
    ~tree
    (ali :fasta workflow)
    : phylotree directory workflow =

    let config_dir = dest // "Configuration" in
    let results_species = dest // "Species_tree/" in
    let results_genes = dest // "Gene_trees/" in
    workflow ~descr:("phyldog_by_fam" ^ descr) ~version:4 ~np:threads ~mem:(1024 * memory) [
    mkdir_p config_dir;
    mkdir_p results_species;
    mkdir_p results_genes;
    mkdir_p (dest // "tmp_phyldog");
    (* Preparing phyldog configuration files*)
    docker env (
      and_list [
        cd (dest // "tmp_phyldog");
        cmd "PhyldogPrepDataByFam.py" [
          option (opt "-datatype" string) datatype ;
          option (opt "-dataformat" string) dataformat ;
          option (opt "-species_tree_file" dep) sptreefile ;
          option (flag string "-topospecies") topospecies ;
          option (opt "-dlopt" string) dlopt ;
          option (opt "-max_gap" float) max_gap ;
          option (opt "-timelimit" int) timelimit ;
          option (flag string "-equgenomes") equgenomes ;
          option (flag string "-topogene") topogene ;
          opt "-link" dep link;
          opt "-family" string family ;
          opt "-seq" dep ali;
          opt "-starting_tree" dep tree;
          opt "-species_tree_resdir" ident results_species;
          opt "-gene_trees_resdir" ident results_genes;
          opt "-optdir" ident config_dir ;
        ];
        cmd "sh" [ file_dump (phyldog_script ~family ~config_dir ~tree ~results_species ~results_genes) ];
      ]
    )
    (*
    (* Run phyldog *)
    cmd "mpirun" [
            opt "-np" ident np ;
            string "phyldog";
            seq ~sep:"=" [string "param";  ident (config_dir // "GeneralOptions.txt") ];
            ];
    *)
    ]

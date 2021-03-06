(*
# File: BlastPlus.ml
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

open Core_kernel.Std
open Bistro.Std
open Bistro.EDSL
open Bistro_bioinfo.Std
open Commons

let makeblastdb ?parse_seqids ?hash_index ~dbtype  dbname  (fasta : fasta workflow) : blast_db workflow =
    workflow ~descr:("makeblastdb:" ^ dbname) ~np:1 [
        mkdir_p dest;
        cmd "makeblastdb" ~env [
                    option (flag string "-parse_seqids") parse_seqids ;
                    option (flag string "-hash_index") hash_index ;
                    opt "-in" dep fasta;
                    opt "-dbtype" string dbtype ;
                    string "-out" ; seq ~sep:"/" [ dest; string dbname; string "db" ] ] ;
         ]
   / selector [ dbname ]
